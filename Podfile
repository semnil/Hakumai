platform :osx, '10.10'
inhibit_all_warnings!

target 'Hakumai' do
  use_frameworks!

  pod 'FMDB', '~> 2.6.2'
  pod 'Ono', '~> 1.2.2'
  pod 'Sparkle', '~> 1.14.0'
  pod 'SAMKeychain', '~> 1.5.0'
  # TODO: update to use official branch that supports swift 3.0
  # pod 'XCGLogger', :git => 'https://github.com/DaveWoodCom/XCGLogger.git', :commit => '31aa5c1dd068f6550772e34ba01d667a1b5ff2de'
  pod 'XCGLogger', '~> 5.0.1'

  target 'HakumaiTests' do
    inherit! :search_paths
  end
end

# TODO: remove this workaround after future version of cocoapods released
# workaround for Xcode 8 Beta 3 build issue, http://stackoverflow.com/a/38466703
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['SWIFT_VERSION'] = '3.0'
    end
  end
end
