//
//  SafariCookie.swift
//  Hakumai
//
//  Created by Hiroyuki Onishi on 8/21/16.
//  Copyright © 2016 Hiroyuki Onishi. All rights reserved.
//

import Foundation

private let kCookieFilePath = "/Cookies/Cookies.binarycookies"

// based on https://github.com/icodeforlove/BinaryCookies.swift
class SafariCookie {
    // MARK: - Public Functions
    static func storedCookie(callback: @escaping(String?) -> Void) {
        let libraryDirectory = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0]

        SafariCookie.parse(cookiePath: libraryDirectory + kCookieFilePath) { (error, cookies) in
            guard let cookies = cookies else {
                callback(nil)
                return
            }
            
            for cookie in cookies {
                if cookie.domain == ".nicovideo.jp" && cookie.name == "user_session" {
                    callback(cookie.value)
                    return
                }
            }
            callback(nil)
        }
    }
    
    // MARK: - Private Functions
    private static func parse(cookiePath: String, callback: @escaping(SafariCookieError?, [Cookie]?) -> ()) {
        guard let data = NSData(contentsOf: NSURL(fileURLWithPath: cookiePath) as URL) else {
            return
        }
        SafariCookie.parse(data: data, callback: callback)
    }
    
    private static func parse(cookieURL: NSURL, callback: @escaping(SafariCookieError?, [Cookie]?) -> ()) {
        guard let data = NSData(contentsOf: cookieURL as URL) else {
            return
        }
        SafariCookie.parse(data: data, callback: callback)
    }
    
    private static func parse(data: NSData, callback: @escaping(SafariCookieError?, [Cookie]?) -> ()) {
        let parser = CookieParser()
        DispatchQueue.global(qos: DispatchQoS.QoSClass.background).async {
            do {
                callback(nil, try parser.processCookieData(data: data))
            } catch {
                callback(error as? SafariCookieError, nil)
            }
        }
    }
}

// MARK: - Error
private enum SafariCookieError: Error {
    case badFileHeader
    case invalidEndOfCookieData
    case unexpectedCookieHeaderValue
}

// MARK: - Cookie
private struct Cookie {
    var expiration: Int64
    var creation: Int64
    var domain: String
    var name: String
    var path: String
    var value: String
    var secure: Bool = false
    var http: Bool = false
}

// MARK: - Cookie Parser
private class CookieParser {
    // MARK: - Properties
    private var numPages: UInt32 = 0
    private var pageSizes: [UInt32] = []
    private var pageNumCookies: [UInt32] = []
    private var pageCookieOffsets: [[UInt32]] = []
    private var pages: [BinaryReader] = []
    private var cookieData: [[BinaryReader]] = []
    private var cookies: [Cookie] = []
    
    private var reader: BinaryReader?
    
    // MARK: - Public Functions
    func processCookieData(data: NSData) throws -> [Cookie] {
        reader = BinaryReader(data: data)
        
        let header = reader!.readSlice(length: 4).toString(encoding: String.Encoding.utf8.rawValue)
        
        if (header == "cook") {
            getNumPages()
            getPageSizes()
            getPages()
            
            for (index, _) in pages.enumerated() {
                try getNumCookies(index: index)
                getCookieOffsets(index: index)
                getCookieData(index: index)
                
                for (cookieIndex, _) in cookieData[index].enumerated() {
                    try parseCookieData(cookie: cookieData[index][cookieIndex])
                }
            }
        } else {
            throw SafariCookieError.badFileHeader
        }
        
        return cookies
    }
    
    // MARK: - Private Functions
    private func parseCookieData(cookie: BinaryReader) throws {
        let macEpochOffset: Int64 = 978307199
        var offsets: [UInt32] = [UInt32]()
        
        _ = cookie.readIntLE(offset: 0)             // unknown
        _ = cookie.readIntLE(offset: 4)             // unknown2
        let flags = cookie.readIntLE(offset: 4 + 4) // flags
        _ = cookie.readIntLE(offset: 8 + 4)         // unknown3
        
        offsets.append(cookie.readIntLE(offset: 12 + 4))    // domain
        offsets.append(cookie.readIntLE(offset: 16 + 4))    // name
        offsets.append(cookie.readIntLE(offset: 20 + 4))    // path
        offsets.append(cookie.readIntLE(offset: 24 + 4))    // value
        
        let endOfCookie = cookie.readIntLE(offset: 28 + 4)
        
        if endOfCookie != 0 {
            throw SafariCookieError.invalidEndOfCookieData
        }
        
        let expiration = (cookie.readDoubleLE(offset: 32 + 8) + macEpochOffset) * 1000
        let creation = (cookie.readDoubleLE(offset: 40 + 8) + macEpochOffset) * 1000
        var domain:String = ""
        var name:String = ""
        var path:String = ""
        var value:String = ""
        var secure:Bool = false
        var http:Bool = false
        
        let nsCookieString = cookie.data.toString(encoding: String.Encoding.ascii.rawValue) as NSString
        
        for (index, offset) in offsets.enumerated() {
            let endOffset = nsCookieString.range(of: "\u{0000}", options: [.caseInsensitive], range: NSMakeRange(Int(offset), nsCookieString.length - Int(offset))).location
            
            let string = nsCookieString.substring(with: NSMakeRange(Int(offset), Int(endOffset) - Int(offset)))
            
            switch index {
            case 0:
                domain = string
            case 1:
                name = string
            case 2:
                path = string
            case 3:
                value = string
            default:
                break
            }
        }
        
        switch flags {
        case 1:
            secure = true
        case 4:
            http = true
        case 5:
            secure = true
            http = true
        default:
            break
        }
        
        cookies.append(Cookie(expiration: expiration, creation: creation, domain: domain, name: name, path: path, value: value, secure: secure, http: http))
    }
    
    private func getNumPages() {
        numPages = reader!.readIntBE()
    }
    
    private func getCookieOffsets(index:Int) {
        let page = pages[index]
        var offsets:[UInt32] = [UInt32]()
        let numCookies = pageNumCookies[index]
        
        for _ in 0 ..< Int(numCookies) {
            offsets.append(page.readIntLE())
        }
        
        pageCookieOffsets.append(offsets)
    }
    
    private func getNumCookies(index:Int) throws {
        let page = pages[index]
        let header = page.readIntBE()
        
        if (header != 256) {
            throw SafariCookieError.unexpectedCookieHeaderValue
        }
        
        pageNumCookies.append(page.readIntLE())
    }
    
    private func getCookieData(index:Int) {
        let page = pages[index]
        let cookieOffsets = pageCookieOffsets[index]
        var pageCookies:[BinaryReader] = [BinaryReader]()
        
        for (_, cookieOffset) in cookieOffsets.enumerated() {
            let cookieSize = page.readIntLE(offset: Int(cookieOffset))
            
            pageCookies.append(BinaryReader(data: page.slice(loc: Int(cookieOffset), len: Int(cookieSize))))
        }
        
        cookieData.append(pageCookies)
    }
    
    private func getPageSizes() {
        for _ in 0 ..< Int(numPages) {
            pageSizes.append(reader!.readIntBE())
        }
    }
    
    private func getPages() {
        for (_, pageSize) in pageSizes.enumerated() {
            pages.append(BinaryReader(data: reader!.readSlice(length: Int(pageSize))))
        }
    }
}

// MARK: - Binary Reader
private class BinaryReader {
    // MARK: - Properties
    fileprivate var data: NSData
    private var bufferPosition:Int = 0
    
    // MARK: - Object Lifecycle
    init(data: NSData) {
        self.data = data
    }
    
    // MARK: - Public Functions
    func readSlice(length: Int) -> NSData {
        let slice = self.data.subdata(with: NSMakeRange(bufferPosition, length))
        bufferPosition += length
        return slice as NSData
    }
    
    func readDoubleBE() -> Int64 {
        let data = readDoubleBE(offset: bufferPosition)
        bufferPosition += 8
        return data
    }
    
    func readDoubleBE(offset:Int) -> Int64 {
        let data = slice(loc: offset, len: 8)
        var out: double_t = 0
        memcpy(&out, data.bytes, MemoryLayout<double_t>.size)
        return Int64(NSSwapHostDoubleToBig(Double(out)).v)
    }
    
    func readIntBE() -> UInt32 {
        let data = readIntBE(offset: bufferPosition)
        bufferPosition += 4
        return data
    }
    
    func readIntBE(offset:Int) -> UInt32 {
        let data = slice(loc: offset, len: 4)
        var out:NSInteger = 0
        data.getBytes(&out, length: MemoryLayout<NSInteger>.size)
        return CFSwapInt32HostToBig(UInt32(out))
    }
    
    func readDoubleLE() -> Int64 {
        let data = readDoubleLE(offset: bufferPosition)
        bufferPosition += 8
        return data
    }
    
    func readDoubleLE(offset:Int) -> Int64 {
        let data = slice(loc: offset, len: 8)
        var out:double_t = 0
        memcpy(&out, data.bytes, MemoryLayout<double_t>.size)
        return Int64(out)
    }
    
    func readIntLE() -> UInt32 {
        let data = readIntLE(offset: bufferPosition)
        bufferPosition += 4
        return data
    }
    
    func readIntLE(offset:Int) -> UInt32 {
        let data = slice(loc: offset, len: 4)
        var out:NSInteger = 0
        data.getBytes(&out, length: MemoryLayout<NSInteger>.size)
        return UInt32(out)
    }
    
    func slice(loc: Int, len: Int) -> NSData {
        return data.subdata(with: NSMakeRange(loc, len)) as NSData
    }
}

// MARK: - Extension
extension NSData {
    func toString(encoding: UInt) -> String {
        return NSString(data: self as Data, encoding: encoding)! as String
    }
}
