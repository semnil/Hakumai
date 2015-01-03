//
//  NicoUtility.swift
//  Hakumai
//
//  Created by Hiroyuki Onishi on 11/10/14.
//  Copyright (c) 2014 Hiroyuki Onishi. All rights reserved.
//

import Foundation
import XCGLogger

// MARK: - protocol

// note these functions are called in background thread, not main thread.
// so use explicit main thread for updating ui in these callbacks.
protocol NicoUtilityDelegate {
    func nicoUtilityDidPrepareLive(nicoUtility: NicoUtility, user: User, live: Live)
    func nicoUtilityDidFailToPrepareLive(nicoUtility: NicoUtility, reason: String)
    func nicoUtilityDidStartListening(nicoUtility: NicoUtility, roomPosition: RoomPosition)
    func nicoUtilityDidReceiveFirstChat(nicoUtility: NicoUtility, chat: Chat)
    func nicoUtilityDidReceiveChat(nicoUtility: NicoUtility, chat: Chat)
    func nicoUtilityDidFinishListening(nicoUtility: NicoUtility)
    func nicoUtilityDidReceiveHeartbeat(nicoUtility: NicoUtility, heartbeat: Heartbeat)
}

// MARK: constant value
private let kCommunityLevelStandRoomTable: [(minLevel: Int, maxLevel: Int, standCount: Int)] = [
    (1, 65, 1),     // a
    (66, 69, 2),    // a, b
    (70, 104, 3),   // a, b, c
    (105, 149, 4),  // a, b, c, d
    (150, 189, 5),  // a, b, c, d, e
    (190, 231, 6),  // a, b, c, d, e, f
    (232, 999, 7)   // a, b, c, d, e, f, g
]

// urls for api
private let kGetPlayerStatusUrl = "http://watch.live.nicovideo.jp/api/getplayerstatus"
private let kGetPostKeyUrl = "http://live.nicovideo.jp/api/getpostkey"
private let kHeartbeatUrl = "http://live.nicovideo.jp/api/heartbeat"
private let kNgScoringUrl:String = "http://watch.live.nicovideo.jp/api/ngscoring"

// urls for scraping
private let kCommunityUrlUser = "http://com.nicovideo.jp/community/"
private let kCommunityUrlChannel = "http://ch.nicovideo.jp/"
private let kUserUrl = "http://www.nicovideo.jp/user/"

// intervals
private let kHeartbeatDefaultInterval: NSTimeInterval = 30

// MARK: - class

class NicoUtility : NSObject, RoomListenerDelegate {
    var delegate: NicoUtilityDelegate?
    
    var live: Live?
    private var user: User?
    private var messageServer: MessageServer?
    
    private var messageServers = [MessageServer]()
    private var roomListeners = [RoomListener]()
    private var receivedFirstChat = [RoomPosition: Bool]()
    
    var cachedUsernames = [String: String]()
    
    private var heartbeatTimer: NSTimer?
    
    // cookie
    var cookie: String?
    
    // logger
    let log = XCGLogger.defaultInstance()
    let fileLog = XCGLogger()

    // MARK: - Object Lifecycle
    private override init() {
        super.init()
        
        self.initializeFileLog()
    }
    
    class var sharedInstance : NicoUtility {
        struct Static {
            static let instance : NicoUtility = NicoUtility()
        }
        return Static.instance
    }
    
    func initializeFileLog() {
        let fileLogPath = NSHomeDirectory() + "/Hakumai.log"
        fileLog.setup(logLevel: .Verbose, showLogLevel: true, showFileNames: true, showLineNumbers: true, writeToFile: fileLogPath)
        
        if let console = fileLog.logDestination(XCGLogger.constants.baseConsoleLogDestinationIdentifier) {
            fileLog.removeLogDestination(console)
        }
    }

    // MARK: - Public Interface
    func connect(liveNumber: Int) {
        if 0 < self.roomListeners.count {
            self.disconnect()
        }
        
        if let cookie = CookieUtility.cookie(CookieUtility.BrowserType.Chrome) {
            self.cookie = cookie
        }
        else {
            let message = "could not get cookie, canceled to connect"
            log.error(message)
            self.delegate?.nicoUtilityDidFailToPrepareLive(self, reason: message)
            return
        }
        
        func success(live: Live, user: User, server: MessageServer) {
            self.log.debug("extracted live: \(live)")
            self.log.debug("extracted server: \(server)")
            
            self.live = live
            self.user = user
            self.messageServer = server
            
            func communitySuccess() {
                self.log.debug("loaded community:\(self.live!.community)")
                
                self.delegate?.nicoUtilityDidPrepareLive(self, user: self.user!, live: self.live!)
                
                self.messageServers = self.deriveMessageServersWithOriginServer(server, community: self.live!.community)
                self.log.debug("derived message servers:")
                for server in self.messageServers {
                    self.log.debug("\(server)")
                }
                
                self.openNewMessageServer()
                self.scheduleHeartbeatTimer(immediateFire: true)
            }
            
            func communityFailure(reason: String) {
                let message = "failed to load community"
                self.log.error(message)
                self.delegate?.nicoUtilityDidFailToPrepareLive(self, reason: message)
                return
            }
            
            self.loadCommunity(self.live!.community, success: communitySuccess, failure: communityFailure)
        }
        
        func failure(reason: String) {
            let message = "could not extract live information: \(reason)"
            self.log.error(message)
            self.delegate?.nicoUtilityDidFailToPrepareLive(self, reason: message)
            return
        }
        
        self.requestGetPlayerStatus(liveNumber, success: success, failure: failure)
    }
    
    func disconnect() {
        for listener in self.roomListeners {
            listener.closeSocket()
        }
        
        self.stopHeartbeatTimer()
        self.delegate?.nicoUtilityDidFinishListening(self)
        self.reset()
    }
    
    func comment(comment: String, anonymously: Bool = true) {
        if self.live == nil || self.user == nil {
            self.log.debug("no available stream, or user")
            return
        }
        
        func success(postKey: String) {
            let roomListener = self.roomListeners[self.messageServer!.roomPosition.rawValue]
            roomListener.comment(self.live!, user: self.user!, postKey: postKey, comment: comment, anonymously: anonymously)
        }
        
        func failure() {
            self.log.error("could not get post key")
        }
        
        self.requestGetPostKey(success, failure: failure)
    }
    
    func loadThumbnail(completion: (imageData: NSData?) -> Void) {
        if self.live?.community.thumbnailUrl == nil {
            log.debug("no thumbnail url")
            completion(imageData: nil)
            return
        }
        
        func httpCompletion(response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in loading thumbnail request")
                completion(imageData: nil)
                return
            }
            
            completion(imageData: data)
        }
        
        self.cookiedAsyncRequest("GET", url: self.live!.community.thumbnailUrl!, parameters: nil, completion: httpCompletion)
    }
    
    func resolveUsername(userId: String, completion: (userName: String?) -> Void) {
        if !self.isRawUserId(userId) {
            completion(userName: nil)
            return
        }
        
        if let cachedUsername = self.cachedUsernames[userId] {
            completion(userName: cachedUsername)
            return
        }
        
        func httpCompletion(response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in resolving username")
                completion(userName: nil)
                return
            }
            
            let username = self.extractUsername(data)
            self.cachedUsernames[userId] = username
            
            completion(userName: username)
        }
        
        self.cookiedAsyncRequest("GET", url: kUserUrl + String(userId), parameters: nil, completion: httpCompletion)
    }
    
    func reportAsNgUser(chat: Chat) {
        func httpCompletion(response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in requesting ng user")
                // TODO: error completion?
                return
            }
            
            log.debug("completed to request ng user")
            
            // TODO: success completion?
        }
        
        let parameters: [String: Any] = [
            "vid": self.live!.liveId!,
            "lang": "ja-jp",
            "type": "ID",
            "locale": "GLOBAL",
            "value": chat.userId!,
            "player": "v4",
            "uid": chat.userId!,
            "tpos": String(Int(chat.date!.timeIntervalSince1970)) + "." + String(chat.dateUsec!),
            "comment": String(chat.no!),
            "thread": String(self.messageServers[chat.roomPosition!.rawValue].thread),
            "comment_locale": "ja-jp"
        ]
        
        self.cookiedAsyncRequest("POST", url: kNgScoringUrl, parameters: parameters, completion: httpCompletion)
    }
    
    func urlStringForUserId(userId: String) -> String {
        return kUserUrl + userId
    }
    
    // MARK: - RoomListenerDelegate Functions
    func roomListenerDidReceiveThread(roomListener: RoomListener, thread: Thread) {
        log.debug("\(thread)")
        self.delegate?.nicoUtilityDidStartListening(self, roomPosition: roomListener.server!.roomPosition)
    }
    
    func roomListenerDidReceiveChat(roomListener: RoomListener, chat: Chat) {
        // open next room, if first comment in the room received
        if chat.premium == .Ippan || chat.premium == .Premium {
            if let room = roomListener.server?.roomPosition {
                if self.receivedFirstChat[room] == nil || self.receivedFirstChat[room] == false {
                    self.receivedFirstChat[room] = true
                    self.openNewMessageServer()
                    
                    self.delegate?.nicoUtilityDidReceiveFirstChat(self, chat: chat)
                }
            }
        }
        
        self.delegate?.nicoUtilityDidReceiveChat(self, chat: chat)
        
        if (chat.comment == "/disconnect" && (chat.premium == .Caster || chat.premium == .System) &&
            chat.roomPosition == .Arena) {
                self.disconnect()
        }
    }
    
    // MARK: - Internal Functions
    // MARK: Get Player Status
    private func requestGetPlayerStatus(liveNumber: Int, success: (live: Live, user: User, messageServer: MessageServer) -> Void, failure: (reason: String) -> Void) {
        func httpCompletion(response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                let message = "error in cookied async request"
                log.error(message)
                failure(reason: message)
                return
            }
            
            let responseString = NSString(data: data, encoding: NSUTF8StringEncoding)
            // log.debug("\(responseString)")
            
            if data == nil {
                let message = "error in unpacking response data"
                log.error(message)
                failure(reason: message)
                return
            }
            
            let (error, code) = self.isErrorResponse(data)
            
            if error {
                log.error(code)
                failure(reason: code)
                return
            }
            
            let live = self.extractLive(data)
            let user = self.extractUser(data)
            
            var messageServer: MessageServer?
            if user != nil {
                messageServer = self.extractMessageServer(data, user: user!)
            }
            
            if live == nil || user == nil || messageServer == nil {
                let message = "error in extracting getplayerstatus response"
                log.error(message)
                failure(reason: message)
                return
            }
            
            success(live: live!, user: user!, messageServer: messageServer!)
        }
        
        self.cookiedAsyncRequest("GET", url: kGetPlayerStatusUrl, parameters: ["v": "lv" + String(liveNumber)], completion: httpCompletion)
    }
    
    // MARK: Community
    private func loadCommunity(community: Community, success: () -> Void, failure: (reason: String) -> Void) {
        func httpCompletion(response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                let message = "error in cookied async request"
                log.error(message)
                failure(reason: message)
                return
            }
            
            let responseString = NSString(data: data, encoding: NSUTF8StringEncoding)
            // log.debug("\(responseString)")
            
            if data == nil {
                let message = "error in unpacking response data"
                log.error(message)
                failure(reason: message)
                return
            }
            
            if community.isChannel() == true {
                self.extractChannelCommunity(data, community: community)
            }
            else {
                self.extractUserCommunity(data, community: community)
            }

            success()
        }
        
        let url = (community.isChannel() == true ? kCommunityUrlChannel : kCommunityUrlUser) + community.community!
        self.cookiedAsyncRequest("GET", url: url, parameters: nil, completion: httpCompletion)
    }
    
    // MARK: Message Server Functions
    func deriveMessageServersWithOriginServer(originServer: MessageServer, community: Community) -> [MessageServer] {
        if community.isUser() == true && community.level == nil {
            // could not read community level (possible ban case)
            return [originServer]
        }
        
        var arenaServer = originServer
        
        if 0 < originServer.roomPosition.rawValue {
            for _ in 1...(originServer.roomPosition.rawValue) {
                arenaServer = arenaServer.previous()
            }
        }
        
        var servers = [arenaServer]
        var standRoomCount = 0
        
        if community.isUser() == true {
            if let level = community.level {
                standRoomCount = self.standRoomCountForCommunityLevel(level)
            }
        }
        else {
            // stand a, b, c, d, e
            standRoomCount = 5
        }
        
        for _ in 1...standRoomCount {
            servers.append(servers.last!.next())
        }
        
        return servers
    }
    
    func standRoomCountForCommunityLevel(level: Int) -> Int {
        var standRoomCount = 0
        
        for (minLevel, maxLevel, standCount) in kCommunityLevelStandRoomTable {
            if minLevel <= level && level <= maxLevel {
                standRoomCount = standCount
                break
            }
        }
        
        return standRoomCount
    }
    
    private func openNewMessageServer() {
        if self.roomListeners.count == self.messageServers.count {
            log.info("already opened max servers.")
            return
        }
        
        let targetServerIndex = self.roomListeners.count
        let targetServer = self.messageServers[targetServerIndex]
        let listener = RoomListener(delegate: self, server: targetServer)
        
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), {
            listener.openSocket()
        })
        
        self.roomListeners.append(listener)
    }
    
    // MARK: Comment
    private func requestGetPostKey(success: (postKey: String) -> Void, failure: () -> Void) {
        if messageServer == nil {
            log.error("cannot comment without messageServer")
            failure()
            return
        }
        
        func httpCompletion(response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in cookied async request")
                failure()
                return
            }
            
            let responseString = NSString(data: data, encoding: NSUTF8StringEncoding)
            log.debug("\(responseString)")
            
            if data == nil {
                log.error("error in unpacking response data")
                failure()
                return
            }
            
            let postKey = (responseString as String).extractRegexpPattern("postkey=(.+)")
            
            if postKey == nil {
                log.error("error in extracting postkey")
                failure()
                return
            }
            
            success(postKey: postKey!)
        }
        
        let thread = messageServer!.thread
        let blockNo = (roomListeners[messageServer!.roomPosition.rawValue].lastRes + 1) / 100
        
        self.cookiedAsyncRequest("GET", url: kGetPostKeyUrl, parameters: ["thread": thread, "block_no": blockNo], completion: httpCompletion)
    }
    
    // MARK: Heartbeat
    private func scheduleHeartbeatTimer(immediateFire: Bool = false, interval: NSTimeInterval = kHeartbeatDefaultInterval) {
        self.stopHeartbeatTimer()
        
        dispatch_async(dispatch_get_main_queue(), {
            self.heartbeatTimer = NSTimer.scheduledTimerWithTimeInterval(interval, target: self, selector: "checkHeartbeat:", userInfo: nil, repeats: true)
            if immediateFire {
                self.heartbeatTimer?.fire()
            }
        })
    }
    
    private func stopHeartbeatTimer() {
        if self.heartbeatTimer == nil {
            return
        }
        
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
    }
    
    func checkHeartbeat(timer: NSTimer) {
        func httpCompletion(response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in checking heartbeat")
                return
            }
            
            let responseString = NSString(data: data, encoding: NSUTF8StringEncoding)
            fileLog.debug("\(responseString)")
            
            let heartbeat = self.extractHeartbeat(data)
            fileLog.debug("\(heartbeat)")
            
            if heartbeat == nil {
                log.error("error in extracting heatbeat")
                return
            }
            
            self.delegate?.nicoUtilityDidReceiveHeartbeat(self, heartbeat: heartbeat!)
            
            if let interval = heartbeat?.waitTime {
                self.stopHeartbeatTimer()
                self.scheduleHeartbeatTimer(immediateFire: false, interval: NSTimeInterval(interval))
            }
        }
        
        let liveId = self.live!.liveId!
        self.cookiedAsyncRequest("GET", url: kHeartbeatUrl, parameters: ["v": liveId], completion: httpCompletion)
    }
    
    // MARK: Misc Utility
    func reset() {
        self.live = nil
        self.user = nil
        self.messageServer = nil
        
        self.messageServers.removeAll(keepCapacity: false)
        self.roomListeners.removeAll(keepCapacity: false)
        self.receivedFirstChat.removeAll(keepCapacity: false)
    }
}