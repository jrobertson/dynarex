#!/usr/bin/ruby

# file: dynarex.rb

require 'nokogiri'
require 'open-uri'
require 'ostruct'
require 'dynarex-import'
require 'line-tree'
require 'rexle'

class Dynarex

  attr_accessor :format_mask, :delimiter, :schema
  
#Create a new dynarex document from 1 of the following options:
#* a local file path
#* a URL
#* a schema string
#    Dynarex.new 'contacts[title,description]/contact(name,age,dob)'
#* an XML string
#    Dynarex.new '<contacts><summary><schema>contacts/contact(name,age,dob)</schema></summary><records/></contacts>'

  def initialize(location=nil)
    @delimiter = ' '
    open(location) if location
  end

  def add(x)
    @doc.add x
    load_records
    self
  end

  def delimiter=(separator)
    @format_mask = @format_mask.to_s.gsub(/\s/, separator)
    @summary[:format_mask] = @format_mask
  end

  def import(options={})
    o = {xml: '', schema: ''}.merge(options)
    h = {xml: o[:xml], schema: @schema, foreign_schema: o[:schema]}
    buffer = DynarexImport.new(h).to_xml
    open(buffer)
    self
  end
  
  def fields
    @fields
  end

  def format_mask=(s)
    @format_mask = s
    @summary[:format_mask] = @format_mask
  end
     
  def schema=(s)
    open s
  end

# Returns the hash representation of the document summary.
  
  def summary
    @summary
  end

#Return a Hash (which can be edited) containing all records.
  
  def records
    @records
  end
  
#Returns a ready-only snapshot of records as a simple Hash.  
  def flat_records
    @flat_records
  end
  
  alias to_h flat_records
  
# Returns all records as a string format specified by the summary format_mask field.  

  def to_doc  
    @doc
  end

  def to_s
xsl_buffer =<<EOF
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
<xsl:output encoding="UTF-8"
            method="text"
            indent="no"
            omit-xml-declaration="yes"/>

  <xsl:template match="*">
    <xsl:for-each select="records/*">[!regex_values]<xsl:text>
</xsl:text>
    </xsl:for-each>
  </xsl:template>
</xsl:stylesheet>
EOF

    #format_mask = XPath.first(@doc.root, 'summary/format_mask/text()').to_s
    format_mask = @doc.element('summary/format_mask/text()')
    dynarex = Dynarex.new

    s = %q(schema="companies/company(name, last_contacted, contact)" delimiter=" # ")
    s.split(/(?=\w+\="[^"]+")/)
    raw_a = s.scan(/\w+\="[^"]+"/)
    a = raw_a.map{|x| r = x.split(/=/); [(r[0] + "=").to_sym, r[1][/^"(.*)"$/,1]] }
    a.each{|name, value| dynarex.method(name).call(value)}

    xslt_format = format_mask.to_s.gsub(/\s(?=\[!\w+\])/,'<xsl:text> </xsl:text>').gsub(/\[!(\w+)\]/, '<xsl:value-of select="\1"/>')
    xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)

    xslt  = Nokogiri::XSLT(xsl_buffer)
    out = xslt.transform(Nokogiri::XML(@doc.to_s))
    out.text

  end
  
  def to_xml() 
    display_xml()
  end
  
#Save the document to a local file.  
  
  def save(filepath=nil)
    filepath ||= @local_filepath
    @local_filepath = filepath
    xml = display_xml()
    File.open(filepath,'w'){|f| f.write xml}
  end
  
#Parses 1 or more lines of text to create or update existing records.

  def parse(buffer='')
    buffer = yield if block_given?          
    string_parse buffer
  end  
  
#Create a record from a hash containing the field name, and the field value.
#  dynarex = Dynarex.new 'contacts/contact(name,age,dob)'
#  dynarex.create name: Bob, age: 52

  def create(arg, id=nil)
    
    rebuild_doc()
    methods = {Hash: :hash_create, String: :create_from_line}
    send (methods[arg.class.to_s.to_sym]), arg, id

    load_records
    self
  end
  
#Create a record from a string, given the dynarex document contains a format mask.
#  dynarex = Dynarex.new 'contacts/contact(name,age,dob)'
#  dynarex.create_from_line 'Tracy 37 15-Jun-1972'  
  
  def create_from_line(line, id=nil)
    t = @format_mask.to_s.gsub(/\[!(\w+)\]/, '(.*)').sub(/\[/,'\[').sub(/\]/,'\]')
    line.match(/#{t}/).captures
    
    a = line.match(/#{t}/).captures
    h = Hash[@fields.zip(a)]
    create h
    self
  end

#Updates a record from an id and a hash containing field name and field value.
#  dynarex.update 4, name: Jeff, age: 38  
  
  def update(id, params={})
    fields = capture_fields(params)


    # for each field update each record field
    record = @doc.element("records/#{@record_name}[@id='#{id.to_s}']")    
    fields.each {|k,v| record.element(k.to_s).text = v if v}
    record.add_attribute(last_modified: Time.now.to_s)

    load_records

    self

  end

#Delete a record.
#  dyarex.delete 3      # deletes record with id 3
  
  def delete(x)        

    if x.to_i.to_s == x.to_s and x[/[0-9]/] then
      @doc.delete("records/*[@id='#{x}']")
    else
      @doc.delete x
    end
    load_records
    self
  end

  def element(x)
    @doc.element x
  end
    
  def sort_by!(&element_blk)
    refresh_doc
    a = @doc.xpath('records/*').sort_by &element_blk
    @doc.delete('records')

    records = Rexle::Element.new 'records'
    a.each {|record| records.add record}
    @doc.root.add records

    load_records
    self
  end
  
  def record(id)
    recordx_to_record @doc.element("records/*[@id='#{id}']")
  end
  
  def record_exists?(id)
    !@doc.element("records/*[@id='#{id}']").nil?
  end

  def xpath(x)
    @doc.xpath x
  end

  private


  def create_find(fields)  
    methods = fields.map do |field|
      "def find_by_#{field}(value) findx_by('#{field}', value) end\n" + \
        "def find_all_by_#{field}(value) findx_all_by('#{field}', value) end"
    end
    self.instance_eval(methods.join("\n"))
  end

  def findx_by(field, value)
    r = @doc.element("records/*[#{field}='#{value}']")
    r ? recordx_to_record(r) : nil
  end

  def findx_all_by(field, value)
    @doc.xpath("records/*[#{field}='#{value}']").map {|x| recordx_to_record x}
  end

  def recordx_to_record(recordx)
    OpenStruct.new(Hash[*@fields.zip(recordx.xpath("*/text()")).flatten])
  end

  def hash_create(params={}, id=nil)

    fields = capture_fields(params)
    record = Rexle::Element.new @record_name
    fields.each do |k,v|
      element = Rexle::Element.new(k.to_s)              
      element.text = v if v
      record.add element
    end
    
    id = (@doc.xpath('max(records/*/attribute::id)').to_i + 1).to_s unless id

    attributes = {id: id, created: Time.now.to_s, last_modified: nil}
    attributes.each {|k,v| record.add_attribute(k, v)}

    @doc.element('records').add record            

  end

  def capture_fields(params)
    fields = Hash[@fields.map {|x| [x,nil]}]
    fields.keys.each {|key| fields[key] = params[key] if params.has_key? key}      
    fields
  end

  
  def display_xml
    rebuild_doc()
    @doc.xml pretty: true
  end

  def rebuild_doc
    
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.send @root_name do
        xml.summary do
          @summary.each{|key,value| xml.send key, value}
        end
        if @records then
          xml.records do

            @records.each do |k, item|
              xml.send(@record_name, id: item[:id], created: item[:created], \
                  last_modified: item[:last_modified]) do
                item[:body].each{|name,value| xml.send name, value}
              end
            end

          end
        end # end of if @records
      end
    end

    @doc = Rexle.new builder.to_xml

  end

  alias refresh_doc display_xml

  def string_parse(buffer)
    raw_header = buffer.slice!(/<\?dynarex[^>]+>/)

    if raw_header then
      header = raw_header[/<?dynarex (.*)?>/,1]
      header.scan(/\w+\="[^"]+\"/).map{|x| r = x.split(/=/); [(r[0] + "=").to_sym, r[1][/^"(.*)"$/,1]] }.each {|name, value|      self.method(name).call(value)}
    end

    # if records already exist find the max id
    i = @doc.xpath('max(records/*/attribute::id)').to_i

    
    # 'a' and 'a_split' just used for validation
    a = @format_mask.scan(/\[!\w+\]/)
    a_split = @format_mask.split(/\[!\w+\]/)
    
    if a.length == 2 and a_split[1].length == 1 then  
      t = "([^#{a_split[1]}]+)" + a_split[1] + "(.*)"
    else
      # convert the format mask into a friendly reg exp string
      t = @format_mask.to_s.gsub(/\[!(\w+)\]/, '(.*)').sub(/\[/,'\[').sub(/\]/,'\]')
    end

    lines = buffer.strip.split(/\r?\n|\r(?!\n)/).map {|x|x.strip.match(/#{t}/).captures}

    a = lines.map do|x| 
      created = Time.now.to_s
      
      h = Hash[@fields.zip(x)]
      [h[@default_key], {id: '', created: created, last_modified: '', body: h}]
    end
    
    h2 = Hash[a]
    
    #replace the existing records hash
    h = @records
    h2.each do |key,item|
      if h.has_key? key then

        # overwrite the previous item and change the timestamps
        h[key][:last_modified] = item[:created]
        item[:body].each do |k,v|
          h[key][:body][k.to_sym] = v
        end
      else
        i += 1
        item[:id] =  i.to_s
        h[key] = item.clone
      end      
    end    
    
    h.each {|key, item| h.delete(key) if not h2.has_key? key}
    #refresh_doc
    #load_records  
    @flat_records = @records.values.map{|x| x[:body]}
    rebuild_doc
    self
  end

  def dynarex_new(s)
    @schema = s
    ptrn = %r((\w+)\[?([^\]]+)?\]?\/(\w+)\(([^\)]+)\))
    root_name, raw_summary, record_name, raw_fields = s.match(ptrn).captures
    summary, fields = [raw_summary || '',raw_fields].map {|x| x.split(/,/).map &:strip}  
    create_find fields

    reserved = %w(require parent)
    raise 'reserved keyword' if (fields & reserved).any?

lines =<<LINES
#{root_name}
  summary#{"\n" + ' ' * 4 + summary.join("\n" + ' ' * 4) unless summary.empty?}
    recordx_type dynarex
    format_mask #{fields.map {|x| "[!%s]" % x}.join(' ')}
    schema #{s}
  records
LINES
    
    @records = {}
    @flat_records = {}
    
    LineTree.new(lines).to_xml
  end

  def attach_record_methods()
    create_find @fields
  end
  
  def open(s)
    
    if s[/</] then # xml
      buffer = s
    elsif s[/\(/] # schema
      buffer = dynarex_new s
    elsif s[/^https?:\/\//] then  # url
      buffer = Kernel.open(s, 'UserAgent' => 'Dynarex-Reader').read
    else # local file
      @local_filepath = s
      buffer = File.open(s,'r').read
    end

    @doc = Rexle.new buffer
    @schema = @doc.root.text('summary/schema')
    @root_name = @doc.root.name
    @summary = summary_to_h    
    @default_key = @doc.element('summary/default_key/text()') 
    @format_mask = @doc.element('summary/format_mask/text()')
   
    @fields = @format_mask.to_s.scan(/\[!(\w+)\]/).flatten.map(&:to_sym) if @format_mask 

    if @schema then
      @record_name, raw_fields = @schema.match(/(\w+)\(([^\)]+)/).captures
      @fields = raw_fields.split(',').map{|x| x.strip.to_sym} unless @fields      
    end

    if @fields then
      @default_key = @fields[0] unless @default_key     
      # load the record query handler methods
      attach_record_methods
    else
      @default_key = @doc.xpath('records/*/*').first.name
    end
    
    if @doc.xpath('records/*').length > 0 then
      @record_name = @doc.element('records/*[1]').name            
      load_records 
    end

  end  

  def load_records
    @records = records_to_h
    @records.instance_eval do
       def delete_item(i)
         self.delete self.keys[i]
       end
    end
      
    #Returns a ready-only snapshot of records as a simple Hash.
    @flat_records = @records.values.map{|x| x[:body]}
  end

  def display()
    puts @doc.to_s
  end
 
  def records_to_h()

    i = @doc.xpath('max(records/*/attribute::id)') || 0
    
    @doc.xpath('records/*').inject({}) do |result,row|

      created = Time.now.to_s
      last_modified = ''
      
      if row.attributes[:id] then
        id = row.attributes[:id]
      else
        i += 1; id = i.to_s
      end

      created = row.attributes[:created] if row.attributes[:created]
      last_modified = row.attributes[:last_modified] if row.attributes[:last_modified]
      body = row.xpath('*').inject({}) do |r,node|
        r.merge node.name.to_sym => node.text.unescape
      end

      result.merge body[@default_key.to_sym] => {id: id, created: created, last_modified: last_modified, body: body}
    end

  end

  def summary_to_h

    @doc.xpath('summary/*').inject({}) do |r,node|
      r.merge node.name.to_s.to_sym => node.text.to_s
    end
  end

end
