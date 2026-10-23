Pod::Spec.new do |s|
    s.name                  = 'SwiftCentrifuge'
    s.module_name           = 'SwiftCentrifuge'
    s.swift_version         = '5.0'
    s.version               = '0.11.0'

    s.homepage              = 'https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift'
    s.summary               = 'Centrifugo and Centrifuge client in Swift'

    s.author                = { 'Alexander Emelin' => 'frvzmb@gmail.com' }
    s.license               = { :type => 'MIT AND Apache-2.0', :file => 'LICENSE' }
    s.platforms             = { :ios => '12.0' }
    s.ios.deployment_target = '12.0'

    s.source_files          = 'Sources/SwiftCentrifuge/*.swift', 'Sources/SwiftCentrifuge/WebSocket/*.swift'
    s.source                = { :git => 'https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift.git', :tag => s.version }
    s.preserve_paths        = 'THIRD_PARTY_NOTICES.md', 'licenses/*.txt'

    s.dependency 'SwiftProtobuf'
end
