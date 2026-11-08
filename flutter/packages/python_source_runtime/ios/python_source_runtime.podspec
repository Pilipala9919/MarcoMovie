Pod::Spec.new do |s|
  s.name = 'python_source_runtime'
  s.version = '0.1.0'
  s.summary = 'App-owned native Python source runtime.'
  s.homepage = 'https://github.com/Pilipala9919/MarcoMovie'
  s.license = { :type => 'GPL-3.0-only', :file => '../../../../LICENSE' }
  s.author = { 'Pilipala' => '' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.vendored_frameworks = 'Frameworks/Python.framework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'OTHER_LDFLAGS' => '$(inherited) -framework Python'
  }
end
