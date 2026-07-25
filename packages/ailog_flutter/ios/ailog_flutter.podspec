#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint ailog_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'ailog_flutter'
  s.version          = '0.2.0'
  s.summary          = 'ailog Flutter addon: auto-hooked error reporting and a native (iOS/Android) logging bridge.'
  s.description      = <<-DESC
Flutter addon for ailog. Hooks FlutterError.onError / PlatformDispatcher.onError /
ErrorWidget.builder, records navigation as trace events, and bridges native
(iOS/Android) logging into the same JSONL output via a MethodChannel, with a
direct-write fallback for crashes that happen after the Flutter engine is gone.
                       DESC
  s.homepage         = 'https://github.com/FuruyamaMasayuki/ailog'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'ailog' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'ailog_flutter_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
