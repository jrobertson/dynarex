Gem::Specification.new do |s|
  s.name = 'dynarex'
  s.version = '1.0.7'
  s.summary = 'dynarex'
  s.files = Dir['lib/**/*.rb']
  s.add_dependency('rexle')
  s.add_dependency('dynarex-import')
  s.add_dependency('line-tree')
end
