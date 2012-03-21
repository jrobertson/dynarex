Gem::Specification.new do |s|
  s.name = 'dynarex'
  s.version = '1.1.10'
  s.summary = 'dynarex'
  s.authors = ['James Robertson']
  s.files = Dir['lib/**/*.rb']
  s.add_dependency('rexle')
  s.add_dependency('dynarex-import')
  s.add_dependency('line-tree')
  s.add_dependency('rexle-builder')
  s.add_dependency('rexslt')
  s.add_dependency('dynarex-xslt')
end
