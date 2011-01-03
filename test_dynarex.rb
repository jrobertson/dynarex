#!/usr/bin/ruby

# file: test_dynarex.rb
 
#require 'testdata'
require '/home/james/learning/ruby/testdata'
#require 'dynarex'
require '/home/james/learning/ruby/dynarex'
require 'timecop'
require 'pretty-xml'
include PrettyXML


file = '~/test-ruby/dynarex'
this_path = File.expand_path(file)
#FileUtils.mkdir_p this_path

if this_path != Dir.pwd then
  puts "you must run this from script #{this_path}" 
  exit
end

testdata = Testdata.new('/home/james/learning/ruby/testdata_dynarex.xml')

testdata.paths do |path|

  new_time = Time.local(2011, 1, 2, 19, 45, 9)
  Timecop.freeze(new_time)

  path.tested? 'Creating a new document from a schema' do 

    def path.test(schema) 

      #`rm *`
      dynarex = Dynarex.new schema
      dynarex.to_xml

    end

  end

  path.tested? 'Creating a new record' do 

    def path.test(schema, name, telno) 

      dynarex = Dynarex.new schema
      dynarex.create name: name, telno: telno  
      dynarex.to_xml

    end

  end

  path.tested? 'Importing records' do 

    def path.test(schema, contacts) 

      dynarex = Dynarex.new schema
      dynarex.parse contacts
      dynarex.to_xml

    end

  end

  path.tested? 'Deleting a record' do 

    def path.test(schema, contacts, id) 
      dynarex = Dynarex.new schema
      dynarex.parse contacts
      dynarex.delete id
      dynarex.to_xml
    end

  end

  path.tested? 'Update a record' do 

    def path.test(schema, contacts, id, number) 
      dynarex = Dynarex.new schema
      dynarex.parse contacts
      dynarex.update id, telno: number
      dynarex.to_xml
    end

  end

end

puts testdata.passed?
puts testdata.score
puts testdata.summary.inspect
#puts testdata.success.inspect


