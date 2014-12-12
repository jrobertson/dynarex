Gem::Specification.new do |s|
  s.name = 'dynarex'
  s.version = '1.2.95'
  s.summary = 'The Dynarex gem can create, read, update or delete rows of Dynarex flavoured XMLrecords.'
  s.authors = ['James Robertson']
  s.files = Dir['lib/**/*.rb']
  s.add_runtime_dependency('rexle', '~> 1.0', '>=1.0.11')
  s.add_runtime_dependency('dynarex-import', '~> 0.2', '>=0.2.2')
  s.add_runtime_dependency('line-tree', '~> 0.3', '>=0.3.17')
  s.add_runtime_dependency('rexle-builder', '~> 0.1', '>=0.1.9')
  s.add_runtime_dependency('rexslt', '~> 0.4', '>=0.4.2')
  s.add_runtime_dependency('dynarex-xslt', '~> 0.1', '>=0.1.5')
  s.add_runtime_dependency('recordx', '~> 0.1', '>=0.1.11')
  s.add_runtime_dependency('rxraw-lineparser', '~> 0.1', '>=0.1.13')
  s.add_runtime_dependency('rowx', '~> 0.1', '>=0.1.6')
  s.add_runtime_dependency('nokogiri', '~> 1.6', '>=1.6.2.1')
  s.add_runtime_dependency('table-formatter', '~> 0.1', '>=0.1.13')
  s.signing_key = '../privatekeys/dynarex.pem'
  s.cert_chain  = ['gem-public_cert.pem']
  s.license = 'MIT'
  s.email = 'james@r0bertson.co.uk'
  s.homepage = 'https://github.com/jrobertson/dynarex'
  s.required_ruby_version = '>= 2.1.2'
end
