#!/usr/bin/env ruby

# file: dynarex.rb

require 'open-uri'
require 'dynarex-import'
require 'line-tree'
require 'rexle'
require 'rexle-builder'
require 'rexslt'
require 'dynarex-xslt'
require 'recordx'
require 'rxraw-lineparser'
require 'yaml'
require 'rowx'

class Dynarex

  attr_accessor :format_mask, :delimiter, :xslt_schema, :schema, :order
  
  def self.gem_url() 'http://www.jamesrobertson.eu/ruby/dynarex#1.2.11'  end
  
#Create a new dynarex document from 1 of the following options:
#* a local file path
#* a URL
#* a schema string
#    Dynarex.new 'contacts[title,description]/contact(name,age,dob)'
#* an XML string
#    Dynarex.new '<contacts><summary><schema>contacts/contact(name,age,dob)</schema></summary><records/></contacts>'

  def initialize(location=nil)
    #puts Rexle.version
    @delimiter = ' '   
    open(location) if location
    @dirty_flag = false
  end

  def add(x)
    @doc.root.add x
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
  
  def inspect()
    "<object #%s>" % [self.object_id]
  end
  
  def order=(value)
    
    self.summary.merge!({order: value})    
    if @order == 'ascending' and value == 'descending' then
      sort_records
    elsif @order == 'descending' and value == 'ascending'
      sort_records
    end    
    @order = value
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
    load_records if @dirty_flag == true
    @records
  end
  
#Returns a ready-only snapshot of records as a simple Hash.  
  def flat_records
    load_records if @dirty_flag == true
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
    format_mask = @doc.root.element('summary/format_mask/text()')
    xslt_format = format_mask.to_s.gsub(/\s(?=\[!\w+\])/,'<xsl:text> </xsl:text>').gsub(/\[!(\w+)\]/, '<xsl:value-of select="\1"/>')
    
    xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)

    #jr250711 xslt  = Nokogiri::XSLT(xsl_buffer)
    #jr250711 out = xslt.transform(Nokogiri::XML(@doc.to_s))
    #jr250811 puts 'xsl_buffer: ' + xsl_buffer
    #jr250811 puts 'doc_to_s: ' + @doc.to_s
    #jr260711 out.text
    #jr231211 Rexslt.new(xsl_buffer, @doc.to_s).to_s

  end

  def to_xml(opt={}) 
    display_xml(opt)
  end
  
#Save the document to a local file.  
  
  def save(*args)
    # args = [filepath=nil, opt={}]
    opt, filepath = args.reverse
    filepath ||= @local_filepath
    @local_filepath = filepath
    xml = display_xml(opt)
    buffer = block_given? ? yield(xml) : xml
    File.open(filepath,'w'){|f| f.write buffer }
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
    
    #jr291012 rebuild_doc()
    #jr291012 (load_records; rebuild_doc) if @dirty_flag == true
    methods = {Hash: :hash_create, String: :create_from_line}
    send (methods[arg.class.to_s.to_sym]), arg, id

    #jr291012load_records
    @dirty_flag = true
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
    record = @doc.root.element("records/#{@record_name}[@id='#{id.to_s}']")    
    fields.each {|k,v| record.element(k.to_s).text = v if v}
    record.add_attribute(last_modified: Time.now.to_s)

    @dirty_flag = true

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
    @dirty_flag = true
    self
  end

  def element(x)
    @doc.root.element x
  end    
  
  def sort_by!(&element_blk)
    refresh_doc
    a = @doc.root.xpath('records/*').sort_by &element_blk
    @doc.root.delete('records')

    records = Rexle::Element.new 'records'

    a.each {|record| records.add record}

    @doc.root.add records

    load_records
    self
  end  

  def rebuild_doc

    reserved_keywords = ( 
                          Object.public_methods | \
                          Kernel.public_methods | \
                          public_methods + [:method_missing]
                        )
    
    xml = RexleBuilder.new
    a = xml.send @root_name do
      xml.summary do
        @summary.each{|key,value| xml.send key, value}
      end
      if @records then
        xml.records do

          @records.each do |k, item|
            #p 'foo ' + item.inspect
            xml.send(@record_name, {id: item[:id], created: item[:created], \
                last_modified:  item[:last_modified]}, '') do
              item[:body].each do |name,value| 
                #name = name.to_s.prepend('._').to_sym if reserved_keywords.include? name
                name = ('._' + name.to_s).to_sym if reserved_keywords.include? name
                val = value.send(value.is_a?(String) ? :to_s : :to_yaml)                
                xml.send(name, val.gsub('>','&gt;').gsub('<','&lt;'))
              end
            end
          end

        end
      else
        xml.records
      end # end of if @records
    end

    @doc = Rexle.new a
  end
  
  def record(id)
    recordx_to_record @doc.root.element("records/*[@id='#{id}']")
  end
  
  def record_exists?(id)
    !@doc.root.element("records/*[@id='#{id}']").nil?
  end

  def to_xslt(opt={})    
    h = {limit: -1}.merge(opt)
    xslt = DynarexXSLT.new(schema: @schema, xslt_schema: @xslt_schema).to_xslt    
    return xslt
  end
  
  def to_rss(opt={}, xslt=nil)
    
    unless xslt then
      
      h = {limit: 11}.merge(opt)
      doc = Rexle.new(self.to_xslt)
      e = doc.element('//xsl:apply-templates[2]')
      doc2 = Rexle.new "<xsl:sort order='descending' data-type='number' select='@id'/>"
      e.add doc2.root
      
      e2 = doc.root.element('xsl:template[3]')
      item = e2.element('item')
      new_item = item.deep_clone
      item.delete
      
      xslif = Rexle.new("<xsl:if test='position() &lt; #{h[:limit]}'/>").root
      e2.add xslif.root
      
      pubdate = Rexle.new("<pubDate><xsl:value-of select='pubDate'></xsl:value-of></pubDate>").root
      new_item.add pubdate      
      xslif.add new_item      

      xslt = doc.xml      
    end
    
    doc = self.to_doc
    doc.root.xpath('records/*').each do |x|
      raw_dt = DateTime.parse x.attributes[:created]
      dt = raw_dt.strftime("%a, %d %b %Y %H:%M:%S %z")
      x.add Rexle::Element.new('pubDate').add_text dt.to_s 
    end

    xml = Rexslt.new(xslt, doc.xml).to_s
    Rexle.new("<rss version='2.0'>%s</rss>" % xml).xml(pretty: true)
  end
  
  def xpath(x)
    @doc.root.xpath x
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
    (load_records; rebuild_doc) if @dirty_flag == true
    r = @doc.root.element("records/*[#{field}='#{value}']")
    r ? recordx_to_record(r) : nil
  end

  def findx_all_by(field, value)
    @doc.root.xpath("records/*[#{field}='#{value}']").map {|x| recordx_to_record x}
  end

  def recordx_to_record(recordx)
    RecordX.new(Hash[*@fields.zip(recordx.xpath("*/text()")).flatten], self, recordx.attributes[:id])
  end

  def hash_create(raw_params={}, id=nil)

    params = Hash[raw_params.keys.map(&:to_sym).zip(raw_params.values)]

    fields = capture_fields(params)    
    record = Rexle::Element.new @record_name

    fields.each do |k,v|
      element = Rexle::Element.new(k.to_s)              
      element.root.text = v.to_s.gsub('<','&lt;').gsub('>','&gt;') if v
      record.add element if record
    end
    
    id = (@doc.root.xpath('max(records/*/attribute::id)') || '0').succ unless id

    attributes = {id: id.to_s, created: Time.now.to_s, last_modified: nil}
    attributes.each {|k,v| record.add_attribute(k, v)}
    if @order == 'descending' then
      element = @doc.root.element('records/.[1]')
      if element then
        element.insert_before record
      else
        @doc.root.element('records').add record
      end       
      
    else
      @doc.root.element('records').add record            
    end

  end

  def capture_fields(params)
    fields = Hash[@fields.map {|x| [x,nil]}]
    fields.keys.each {|key| fields[key] = params[key.to_sym] if params.has_key? key.to_sym}      
    fields
  end
  
  def display_xml(opt={})

    load_records if @dirty_flag == true
    rebuild_doc()
    @doc.xml(opt) #jr230711 pretty: true
  end


  alias refresh_doc display_xml

  def string_parse(buffer)
    raw_header = buffer.slice!(/<\?dynarex[^>]+>/)

    if raw_header then
      header = raw_header[/<?dynarex (.*)?>/,1]
      header.scan(/\w+\s*=\s*(?:"[^"]+"|'[^']+')/).map\
          {|x| r = x.split(/=/,2); [(r[0].rstrip + "=").to_sym, \
              r[1][/^\s*"(.*)"$/,1]] }.each \
                {|name, value|      self.method(name).call(value)}
    end

    # if records already exist find the max id
    i = @doc.root.xpath('max(records/*/attribute::id)').to_i
    
    raw_summary = schema[/\[([^\]]+)/,1]
    r = buffer[/--\+(.*)/m,1]
    buffer = r if r
    raw_lines = buffer[/(--\+)?(.*)/m,2].gsub(/^\s*#[^\n]+/,'').gsub(/\n\n/,"\n")\
        .strip.split(/\r?\n|\r(?!\n)/)

    raw_lines.reverse! if @order == 'descending'

    if raw_summary then
      a_summary = raw_summary.split(',').map(&:strip)
      
      @summary = {}

      while not raw_lines.empty? and \
          raw_lines.first[/#{a_summary.join('|')}:\s+[\w\*\-\+]+/] do
        label, val = raw_lines.shift.match(/(\w+):\s+([^$]+)$/).captures
        @summary[label] = val
      end
    end

    @summary[:recordx_type] = 'dynarex'
    @summary[:schema] = @schema
    @summary[:format_mask] = @format_mask

    lines = case raw_lines.first
      
      when '---'

        yaml = YAML.load raw_lines.join("\n")

        yamlize = lambda {|x| (x.is_a? Array) ? x.to_yaml : x}
        
        yprocs = {
          Hash: lambda {|y|
            y.map do |k,v| 
              procs = {Hash: proc {|x| x.values}, Array: proc {v}}
              values = procs[v.class.to_s.to_sym].call(v).map(&yamlize)
              [k, *values]
            end
          },
          Array: lambda {|y| y.map {|x2| x2.map(&yamlize)} }
        }

        yprocs[yaml.class.to_s.to_sym].call yaml      
        
      when '--+'
        
        raw_lines.shift
        xml = RowX.new(raw_lines.join("\n")).to_xml
        Rexle.new(xml).root.xpath('item').map{|x| x.xpath('*/text()')}

    else
        
      raw_lines.map.with_index do |x,i|

        begin
          field_names, field_values = RXRawLineParser.new(@format_mask).parse(x)
        rescue
          raise "input file parser error at line " + (i + 1).to_s + ' --> ' + x
        end
        field_values
      end
      
    end
    
    a = lines.map do|x| 
      created = Time.now.to_s
      h = Hash[@fields.zip(x.map{|t| t.to_s[/^---/] ? YAML.load(t) : t})]
      [h[@default_key], {id: '', created: created, last_modified: '', body: h}]
    end

    h2 = Hash[a]
    
    #replace the existing records hash
    h = @records
    i = 0
    h2.each do |key,item|
      if h.has_key? key then

        # overwrite the previous item and change the timestamps
        h[key][:last_modified] = item[:created]
        item[:body].each do |k,v|
          h[key][:body][k.to_sym] = v
        end
      else        
        item[:id] = (@order == 'descending' ? (h2.count) - i : i+ 1).to_s
        i += 1
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
    
    if s.match(ptrn) then
      @root_name, raw_summary, record_name, raw_fields = s.match(ptrn).captures 
      summary, fields = [raw_summary || '',raw_fields].map {|x| x.split(/,/).map &:strip}  
      create_find fields
      
      reserved = %w(require parent)
      raise 'reserved keyword' if (fields & reserved).any?
      
    else
      ptrn = %r((\w+)\[?([^\]]+)?\]?)
      @root_name, raw_summary = s.match(ptrn).captures
      summary = raw_summary.split(/,/).map &:strip

    end

    format_mask = fields ? fields.map {|x| "[!%s]" % x}.join(' ') : ''

    @summary = Hash[summary.zip([''] * summary.length).flatten.each_slice(2)\
                    .map{|x1,x2| [x1.to_sym,x2]}]
    @summary.merge!({recordx_type: 'dynarex', format_mask: format_mask, schema: s})
    @records = {}
    @flat_records = {}
    
    rebuild_doc

  end

  def attach_record_methods()
    create_find @fields
  end
  
  def open(s)
    
    if s[/</] then # xml
      buffer = s
    elsif s[/[\[\(]/] # schema
      dynarex_new(s)
    elsif s[/^https?:\/\//] then  # url
      buffer = Kernel.open(s, 'UserAgent' => 'Dynarex-Reader').read
    else # local file
      @local_filepath = s
      buffer = File.open(s,'r').read
    end

    @doc = Rexle.new(buffer) unless @doc
    @schema = @doc.root.text('summary/schema')
    @root_name = @doc.root.name
    @summary = summary_to_h

    @order = @summary[:order] if @summary.has_key? :order

    @default_key = @doc.root.element('summary/default_key/text()') 
    @format_mask = @doc.root.element('summary/format_mask/text()')
   
    @fields = @format_mask.to_s.scan(/\[!(\w+)\]/).flatten.map(&:to_sym) if @format_mask 

    if @schema and @schema.match(/(\w+)\(([^\)]+)/) then
      @record_name, raw_fields = @schema.match(/(\w+)\(([^\)]+)/).captures
      @fields = raw_fields.split(',').map{|x| x.strip.to_sym} unless @fields
    end

    if @fields then
      @default_key = @fields[0] unless @default_key     
      # load the record query handler methods
      attach_record_methods
    else

      #jr080912 @default_key = @doc.root.xpath('records/*/*').first.name

      @default_key = @doc.root.element('records/./.[1]').name
    end

    if @doc.root.xpath('records/*').length > 0 then
      @record_name = @doc.root.element('records/*[1]').name            
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
    @dirty_flag = false
  end

  def display()
    puts @doc.to_s
  end
 
  def records_to_h()

    i = @doc.root.xpath('max(records/*/attribute::id)') || 0
    fields = @doc.root.text('summary/schema')[/\(.*\)/].scan(/\w+/)
    
    @doc.root.xpath('records/*').inject({}) do |result,row|

      created = Time.now.to_s
      last_modified = ''

      if row.attributes[:id] then
        id = row.attributes[:id]
      else
        i += 1; id = i.to_s
      end

      created = row.attributes[:created] if row.attributes[:created]
      last_modified = row.attributes[:last_modified] if row.attributes[:last_modified]

      body = fields.inject({}) do |r,field|
        
        node = row.element field
        
        if node then
          text = node.text.unescape
          r.merge node.name.to_sym => (text[/^--- |^\[/] ? YAML.load(text) : text)
        else
          r
        end
      end      

      result.merge body[@default_key.to_sym] => {id: id, created: created, last_modified: last_modified, body: body}
    end

  end

  def sort_records
xsl =<<XSL
<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">

<xsl:template match="*">
<xsl:element name="{name()}"><xsl:text>
  </xsl:text>
  <xsl:copy-of select="summary"/><xsl:text>
  </xsl:text>
  <xsl:apply-templates select="records"/>
</xsl:element>
</xsl:template>
<xsl:template match="records">
<records><xsl:text>
  </xsl:text>
<xsl:for-each select="child::*">
  <xsl:sort order="descending"/>
  <xsl:text>  </xsl:text><xsl:copy-of select="."/><xsl:text>
  </xsl:text>
</xsl:for-each>
</records><xsl:text>
</xsl:text>
</xsl:template>

</xsl:stylesheet>
XSL

    @doc = Rexle.new(Rexslt.new(xsl, self.to_xml).to_s)
    @dirty_flag = true
  end
  
  def summary_to_h

    @doc.root.xpath('summary/*').inject({}) do |r,node|
      r.merge node.name.to_s.to_sym => node.text.to_s
    end
  end

end
