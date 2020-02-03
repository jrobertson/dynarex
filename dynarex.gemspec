Gem::Specification.new do |s|
  s.name = 'dynarex'
  s.version = '1.8.22'
  s.summary = 'The Dynarex gem creates, reads, updates or delete rows of ' + 
      'Dynarex flavoured XML records.'
  s.authors = ['James Robertson']
  s.files = Dir['lib/dynarex.rb']
  s.add_runtime_dependency('dynarex-import', '~> 0.2', '>=0.2.2')
  s.add_runtime_dependency('rexle-builder', '~> 0.6', '>=0.6.0')
  s.add_runtime_dependency('rexslt', '~> 0.6', '>=0.6.13')
  s.add_runtime_dependency('dynarex-xslt', '~> 0.1', '>=0.1.7')
  s.add_runtime_dependency('recordx', '~> 0.5', '>=0.5.4')
  s.add_runtime_dependency('rxraw-lineparser', '~> 0.2', '>=0.2.0')
  s.add_runtime_dependency('rowx', '~> 0.7', '>=0.7.0')
  s.add_runtime_dependency('table-formatter', '~> 0.7', '>=0.7.0')
  s.add_runtime_dependency('kvx', '~> 0.8', '>=0.8.1')
  s.signing_key = '../privatekeys/dynarex.pem'
  s.cert_chain  = ['gem-public_cert.pem']
  s.license = 'MIT'
  s.email = 'james@jamesrobertson.eu'
  s.homepage = 'https://github.com/jrobertson/dynarex'
  s.required_ruby_version = '>= 2.1.2'
end
