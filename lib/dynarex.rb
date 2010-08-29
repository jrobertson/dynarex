#!/usr/bin/ruby

# file: dynarex.rb

require 'rexml/document'
require 'nokogiri'
require 'open-uri'
require 'builder'
require 'ostruct'

class Dynarex
  include REXML 

#Create a new dynarex document from 1 of the following options:
#* a local file path
#* a URL
#* a schema string
#    Dynarex.new 'contacts[title,description]/contact(name,age,dob)'
#* an XML string
#    Dynarex.new '<contacts><summary><schema>contacts/contact(name,age,dob)</schema></summary><records/></contacts>'

  def initialize(location)
    open(location)
  end
  
  def fields
    @fields
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

    format_mask = XPath.first(@doc.root, 'summary/format_mask/text()').to_s

    xslt_format = format_mask.to_s.gsub(/\s(?=\[!\w+\])/,'<xsl:text> </xsl:text>').gsub(/\[!(\w+)\]/, '<xsl:value-of select="\1"/>')
    xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)

    xslt  = Nokogiri::XSLT(xsl_buffer)
    out = xslt.transform(Nokogiri::XML(@doc.to_s))
    out.text
  end
  
  def to_xml
    display_xml()
  end
  
#Save the document to a local file.  
  
  def save(filepath=nil)
    filepath ||= @local_filepath
    xml = display_xml()
    File.open(filepath,'w'){|f| f.write xml}
  end
  
#Parses 1 or more lines of text to create or update existing records.

  def parse(buffer)
    i = XPath.match(@doc.root, 'records/*/attribute::id').max_by(&:value).to_s.to_i
    t = @format_mask.to_s.gsub(/\[!(\w+)\]/, '(.*)').sub(/\[/,'\[').sub(/\]/,'\]')
    lines = buffer.split(/\r?\n|\r(?!\n)/).map {|x|x.match(/#{t}/).captures}

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
    self
  end  
  
#Create a record from a hash containing the field name, and the field value.
#  dynarex = Dynarex.new 'contacts/contact(name,age,dob)'
#  dynarex.create name: Bob, age: 52

  def create(arg, id=nil)
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
    record = XPath.first(@doc.root, "records/#{@record_name}[@id=#{id.to_s}]")
    fields.each {|k,v| record.elements[k.to_s].text = v if v}
    record.add_attribute('last_modified', Time.now.to_s)

    load_records
    self
  end

#Delete a record.
#  dyarex.delete 3      # deletes record with id 3
  
  def delete(id)        
    node = XPath.first(@doc.root, "records/*[@id='#{id}']")
    node.parent.delete node        
    load_records
    self
  end
  
  def sort_by!(&element_blk)
    refresh_doc
    a = XPath.match(@doc.root, 'records/*').sort_by &element_blk
    records = XPath.first(@doc.root, 'records')
    records.parent.delete records
    records = Element.new 'records'
    a.each {|record| records.add record}
    @doc.root.add records
    load_records
    self
  end
  
  def record(id)
    h = Hash[*XPath.match(@doc.root, "records/*[@id='#{id}']/*").map {|x| [x.name, x.text]}.flatten]
    OpenStruct.new h    
  end

  private
  
  def hash_create(params={}, id=nil)
    fields = capture_fields(params)
    record = Element.new @record_name
    fields.each do |k,v|
      element = Element.new(k.to_s)       
      element.text = v if v
      record.add element
    end

    unless id
      ids = XPath.match(@doc.root,'records/*/attribute::id').map {|x| x.value.to_i}
      id = ids.empty? ? (id || 1) : ids.max.succ
    end

    attributes = {id: id, created: Time.now.to_s, last_modified: nil}
    attributes.each {|k,v| record.add_attribute(k.to_s, v)}
    @doc.root.elements['records'].add record      
  end

  def capture_fields(params)
    fields = Hash[@fields.map {|x| [x,nil]}]
    fields.keys.each {|key| fields[key] = params[key] if params.has_key? key}      
    fields
  end

  
  def display_xml
    
    xml = Builder::XmlMarkup.new( :target => buffer='', :indent => 2 )
    xml.instruct! :xml, :version => "1.0", :encoding => "UTF-8"

    xml.send @root_name do
      xml.summary do
        @summary.each{|key,value| xml.send key, value}
      end
      xml.records do
        if @records then
          @records.each do |k, item|
            xml.send(@record_name, id: item[:id], created: item[:created], \
                last_modified: item[:last_modified]) do
              item[:body].each{|name,value| xml.send name, value}
            end
          end
        end
      end
    end

    @doc = Document.new buffer
    buffer

  end

  alias refresh_doc display_xml

  def dynarex_new(s)
    ptrn = %r((\w+)\[?([^\]]+)?\]?\/(\w+)\(([^\)]+)\))
    root_name, raw_summary, record_name, raw_fields = s.match(ptrn).captures
    summary, fields = [raw_summary || '',raw_fields].map {|x| x.split(/,/).map &:strip}  

    xml = Builder::XmlMarkup.new( target: buffer='', indent: 2 )
    xml.instruct! :xml, version: "1.0", encoding: "UTF-8"

    xml.send root_name do
      xml.summary do
        summary.each do |item|        
          xml.send item
        end
        xml.recordx_type 'dynarex'
        xml.format_mask fields.map {|x| "[!%s]" % x}.join(' ')
        xml.schema s
      end
      xml.records
    end
    
    @records = {}
    @flat_records = {}
    
    buffer
  end

  def attach_record_methods()
    @fields.each do |field|
      self.instance_eval(
%Q(def find_by_#{field}(s)
 Hash[@fields.zip(XPath.match(@doc.root, "records/*[#{field}='\#{s}']/*/text()").map &:to_s)]
end))
    end    
  end
  
  def open(s)
    if s[/\(/] then  # schema
      buffer = dynarex_new s
    elsif s[/^https?:\/\//] then  # url
      buffer = Kernel.open(s, 'UserAgent' => 'Dynarex-Reader').read
    elsif s[/\</] # xml
      buffer = s
    else # local file
      @local_filepath = s
      buffer = File.open(s,'r').read
    end

    @doc = Document.new buffer
    @schema = @doc.root.text('summary/schema')
    @root_name = @doc.root.name
    @summary = summary_to_h    
    @default_key = XPath.first(@doc.root, 'summary/default_key/text()')
    @format_mask = XPath.first(@doc.root, 'summary/format_mask/text()')
   
    @fields = @format_mask.to_s.scan(/\[!(\w+)\]/).flatten.map(&:to_sym) if @format_mask 

    if @schema then
      @record_name, raw_fields = @schema.match(/(\w+)\(([^\)]+)/).captures
      @fields = raw_fields.split(',').map{|x| x.strip.to_sym} unless @fields      
    end

    if @fields then
      @default_key = @fields[0] unless @default_key     
      # load the record query handler methods
      attach_record_methods
    end
    
    if XPath.match(@doc.root, 'records/*').length > 0 then
      @record_name = XPath.first(@doc.root, 'records/*[1]').name      
      load_records 
    end

  end  

  def load_records
    @records = records_to_h
    @flat_records = flat_records_to_h
  end

  def display()
    puts @doc.to_s
  end

#Returns a ready-only snapshot of records as a simple Hash.
  
  def flat_records_to_h
    XPath.match(@doc.root, 'records/*').map do |row|
      XPath.match(row, '*').inject({}) do |r,node|
        r[node.name.to_s.to_sym] = node.text.to_s
        r
      end
    end
  end

  def records_to_h()
    i = XPath.match(@doc.root, 'records/*/attribute::id').max_by(&:value).to_s.to_i
    
    ah = XPath.match(@doc.root, 'records/*').map do |row|
      
      created = Time.now.to_s
      last_modified = ''
      
      if row.attribute('id') then
        id = row.attribute('id').value.to_s 
      else
        i += 1; id = i.to_s
      end
      created = row.attribute('created').value.to_s if row.attribute('created')
      last_modified = row.attribute('last_modified').value.to_s if row.attribute('last_modified')
      body = XPath.match(row, '*').inject({}) do |r,node|
        r[node.name.to_s.to_sym] = node.text.to_s
        r
      end

      [body[@default_key],{id: id, created: created, last_modified: \
          last_modified, body: body}]
    end
    Hash[*ah.flatten]
  end

  def summary_to_h
    XPath.match(@doc.root, 'summary/*').inject({}) do |r,node|
      r[node.name.to_s.to_sym] = node.text.to_s
      r
    end
  end

end

