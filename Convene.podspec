Pod::Spec.new do |s|
  s.name             = 'Convene'
  s.version          = '1.0.0'
  s.summary          = 'Nearby devices find each other and exchange UTF-8 messages on the LAN.'
  s.description      = <<-DESC
    Convene is a host/guest channel: Bonjour discovery, one TCP session, string payloads.
    The message format is defined by your app. Host publishes; Guest discovers and connects.
  DESC
  s.homepage         = 'https://github.com/17746213210/Convene'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Convene' => 'convene@localpods.dev' }
  s.source           = { :git => 'https://github.com/17746213210/Convene.git', :tag => s.version.to_s }
  s.swift_version    = '5.9'
  s.ios.deployment_target  = '13.0'
  s.tvos.deployment_target = '13.0'
  s.osx.deployment_target  = '10.15'
  s.frameworks       = 'Foundation', 'Network'

  s.subspec 'Core' do |ss|
    ss.source_files = 'Sources/ConveneCore/**/*.swift'
  end

  s.subspec 'Host' do |ss|
    ss.dependency 'Convene/Core'
    ss.source_files = 'Sources/ConveneHost/**/*.swift'
  end

  s.subspec 'Guest' do |ss|
    ss.dependency 'Convene/Core'
    ss.source_files = 'Sources/ConveneGuest/**/*.swift'
  end
end
