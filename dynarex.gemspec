Gem::Specification.new do |s|
  s.name = 'dynarex'
  s.version = '1.2.62'
  s.summary = 'dynarex'
  s.authors = ['James Robertson']
  s.files = Dir['lib/**/*.rb']
  s.add_dependency('rexle')
  s.add_dependency('dynarex-import')
  s.add_dependency('line-tree')
  s.add_dependency('rexle-builder')
  s.add_dependency('rexslt')
  s.add_dependency('dynarex-xslt')
  s.add_dependency('recordx')
  s.add_dependency('rxraw-lineparser')
  s.add_dependency('rowx')
  s.add_dependency('nokogiri')
  s.add_dependency('table-formatter')
  s.signing_key = '../privatekeys/dynarex.pem'
  s.cert_chain  = ['gem-public_cert.pem']
  s.license = 'MIT'
  s.email = 'james@r0bertson.co.uk'
  s.homepage = 'https://github.com/jrobertson/dynarex'
end
