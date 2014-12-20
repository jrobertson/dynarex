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
require 'nokogiri'
require 'ostruct'
require 'table-formatter'


class Dynarex

  attr_accessor :format_mask, :delimiter, :xslt_schema, :schema, 
      :order, :type, :limit_by, :xslt
  
  
#Create a new dynarex document from 1 of the following options:
#* a local file path
#* a URL
#* a schema string
#    Dynarex.new 'contacts[title,description]/contact(name,age,dob)'
#* an XML string
#    Dynarex.new '<contacts><summary><schema>contacts/contact(name,age,dob)</schema></summary><records/></contacts>'

  def initialize(rawx=nil)
    #puts Rexle.version
    @delimiter = ''   
    openx(rawx.clone) if rawx
    if @order == 'descending' then
      @records = records_to_h(:descending) 
      rebuild_doc
    end
    #jr240913 @dirty_flag = false
  end

  def add(x)
    @doc.root.add x
    @dirty_flag = true
    self
  end

  def all()
    @doc.root.xpath("records/*").map {|x| recordx_to_record x}
  end

  def delimiter=(separator)

    @delimiter = separator

    if separator.length > 0 then 
      @summary[:delimiter] = separator
    else
      @summary.delete :delimiter
    end

    @format_mask = @format_mask.to_s.gsub(/\s/, separator)
    @summary[:format_mask] = @format_mask
  end

  def foreign_import(options={})
    o = {xml: '', schema: ''}.merge(options)
    h = {xml: o[:xml], schema: @schema, foreign_schema: o[:schema]}
    buffer = DynarexImport.new(h).to_xml

    openx(buffer)
    self
  end
  
  def fields
    @fields
  end

  def format_mask=(s)
    @format_mask = s
    @summary[:format_mask] = @format_mask
  end
  
  def insert(raw_params)
    record = make_record(raw_params)
    @doc.root.element('records/*').insert_before record
    @dirty_flag = true
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
    openx s
  end
  
  def type=(v)
    @order = 'descending' if v == 'feed'
    @type = v
    @summary[:type] = v
  end
  
  def limit_by=(val)
    @limit_by = val.to_i
  end

  # Returns the hash representation of the document summary.
  #
  def summary
    @summary
  end

  # Return a Hash (which can be edited) containing all records.
  #
  def records
    
    load_records if @dirty_flag == true
    
    if block_given? then
      yield(@records)
      rebuild_doc
      @dirty_flag = true 
    else
      @records
    end
    
  end
  
  # Returns a ready-only snapshot of records as a simple Hash.  
  #
  def flat_records    
    load_records if @dirty_flag == true
    @flat_records
  end
  
  alias to_h flat_records
  alias to_a flat_records
  
  # Returns an array snapshot of OpenStruct records
  #
  def ro_records
    flat_records.map {|record| OpenStruct.new record }
  end
  
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
    #format_mask = @doc.root.element('summary/format_mask/text()')

    raw_summary_fields = self.summary[:schema][/^\w+\[([^\]]+)\]/,1]
    sumry = ''
    
    if raw_summary_fields then
      summary_fields = raw_summary_fields.split(',') # .map(&:to_sym) 
      sumry = summary_fields.map {|x| x.strip!; x + ': ' + \
                                     self.summary[x.to_sym]}.join("\n") + "\n"
    end

    if @raw_header then
      declaration = @raw_header
    else

      smry_fields = %i(schema)              
      if self.delimiter.length > 0 then
        smry_fields << :delimiter 
      else
        smry_fields << :format_mask
      end
      s = smry_fields.map {|x| "%s=\"%s\"" % \
        [x, self.send(x).gsub('"', '\"') ]}.join ' '
      #declaration = "<?dynarex %s ?>" % s
      declaration = %Q(<?dynarex %s?>\n) % s
    end

    header = declaration + sumry

    if self.summary[:rawdoc_type] == 'rowx' then
      a = self.fields.map do |field|
  "<xsl:if test=\"%s != ''\">
<xsl:text>\n</xsl:text>%s: <xsl:value-of select='%s'/>
  </xsl:if>" % ([field]*3)
      end

      xslt_format = a.join      

      xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)
      xslt  = Nokogiri::XSLT(xsl_buffer)
      out = xslt.transform(Nokogiri::XML(@doc.to_s))
      
      header + "\n--+\n" + out.text
      
    elsif self.delimiter.length > 0 then

      tfo = TableFormatter.new border: false, nowrap: true, divider: self.delimiter
      tfo.source = self.to_h.map{|x| x.values}      
      header + tfo.display

    else
      
      format_mask = self.format_mask
      format_mask.gsub!(/\[[^!\]]+\]/) {|x| x[1] }
      xslt_format = format_mask.gsub(/\s(?=\[!\w+\])/,'<xsl:text> </xsl:text>')
        .gsub(/\[!(\w+)\]/, '<xsl:value-of select="\1"/>')
        
      xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)
      xslt  = Nokogiri::XSLT(xsl_buffer)
      
      out = xslt.transform(Nokogiri::XML(self.to_xml))
      header + "\n" + out.text
    end
                             
    #xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)
    #xslt  = Nokogiri::XSLT(xsl_buffer)
    #out = xslt.transform(Nokogiri::XML(@doc.to_s))
    #jr250811 puts 'xsl_buffer: ' + xsl_buffer
    #jr250811 puts 'doc_to_s: ' + @doc.to_s
    #out.text
    #jr231211 Rexslt.new(xsl_buffer, @doc.to_s).to_s

  end

  def to_xml(opt={}) 
    opt = {pretty: true} if opt == :pretty
    display_xml(opt)
  end
  
#Save the document to a local file.  
  
  def save(filepath=nil, options={})

    opt = {pretty: true}.merge options
    filepath ||= @local_filepath
    @local_filepath = filepath
    xml = display_xml(opt)
    buffer = block_given? ? yield(xml) : xml
    File.open(filepath,'w'){|f| f.write buffer }
  end
  
#Parses 1 or more lines of text to create or update existing records.

  def parse(x=nil)
    if x.is_a? String then
      buffer = x.clone
      buffer = yield if block_given?          
      string_parse buffer
    else
      foreign_import x
    end
  end  


  alias import parse  

#Create a record from a hash containing the field name, and the field value.
#  dynarex = Dynarex.new 'contacts/contact(name,age,dob)'
#  dynarex.create name: Bob, age: 52

  def create(arg, id=nil)
    raise 'Dynarex#create(): input error: no arg provided' unless arg
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

  def default_key=(id)
    @default_key = id.to_sym
    @summary[:default_key] = id
    @fields << id.to_sym
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
      @doc.root.delete("records/*[@id='#{x}']")
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

  def rebuild_doc(state=:internal)

    reserved_keywords = ( 
                          Object.public_methods | \
                          Kernel.public_methods | \
                          public_methods + [:method_missing]
                        )
    
    xml = RexleBuilder.new

    a = xml.send @root_name do

      xml.summary do

        @summary.each do |key,value| 

          xml.send key, value.gsub('>','&gt;')\
            .gsub('<','&lt;')\
            .gsub(/(&\s|&[a-zA-Z\.]+;?)/) {|x| x[-1] == ';' ? x : x.sub('&','&amp;')}

        end
      end

      records = @records.to_a

      if records then

        records.reverse! if @order == 'descending' and state == :external

        xml.records do
           
          records.each do |k, item|
            #p 'foo ' + item.inspect
            xml.send(@record_name, {id: item[:id], created: item[:created], \
                last_modified:  item[:last_modified]}, '') do
              item[:body].each do |name,value| 
                #name = name.to_s.prepend('._').to_sym if reserved_keywords.include? name
                name = ('._' + name.to_s).to_sym if reserved_keywords.include? name
                val = value.send(value.is_a?(String) ? :to_s : :to_yaml)                
                xml.send(name, val.gsub('>','&gt;')\
                  .gsub('<','&lt;')\
                  .gsub(/(&\s|&[a-zA-Z\.]+;?)/) do |x| 
                    x[-1] == ';' ? x : x.sub('&','&amp;')
                  end
                )
              end
            end
          end

        end
      else
        xml.records
      end # end of if @records
    end

    doc = Rexle.new(a)

    if @xslt then
      doc.instructions = [['xml-stylesheet', 
        "title='XSL_formatting' type='text/xsl' href='#{@xslt}'"]]
    end

    return doc if state != :internal
    @doc = doc
  end
  
  def record(id)
    recordx_to_record @doc.root.element("records/*[@id='#{id}']")
  end
  
  alias find record

  def record_exists?(id)
    !@doc.root.element("records/*[@id='#{id}']").nil?
  end

  def to_xslt(opt={})    

    h = {limit: -1}.merge(opt)
    xslt_schema = @xslt_schema || self.summary[:xslt_schema]
    raise 'to_xsl(): xslt_schema nil' unless xslt_schema

    xslt = DynarexXSLT.new(schema: @schema, xslt_schema: @xslt_schema ).to_xslt    
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

      
      pubdate = Rexle.new("<pubDate><xsl:value-of select='pubDate'></xsl:value-of></pubDate>").root
      new_item.add pubdate      
      xslif.add new_item      

      e2.add xslif.root
      xslt = doc.xml      
    end
    
    doc = self.to_doc
    doc.root.xpath('records/*').each do |x|
      raw_dt = DateTime.parse x.attributes[:created]
      dt = raw_dt.strftime("%a, %d %b %Y %H:%M:%S %z")
      x.add Rexle::Element.new('pubDate').add_text dt.to_s 
    end

    #File.open('dynarex.xsl','w'){|f| f.write xslt}
    #File.open('dynarex.xml','w'){|f| f.write doc.xml}
    #xml = Rexslt.new(xslt, doc.xml).to_s
#=begin
    xslt  = Nokogiri::XSLT(xslt)
    out = xslt.transform(Nokogiri::XML(doc.root.xml))
#=end

    #Rexle.new("<rss version='2.0'>%s</rss>" % xml).xml(pretty: true)
    Rexle.new("<rss version='2.0'>%s</rss>" % out).xml(pretty: true)
  end
  
  def xpath(x)
    @doc.root.xpath x
  end

  def xslt=(value)
    
    self.summary.merge!({xslt: value})
    @xslt = value
  end  

  private

  def add_id(a)
    @default_key = :uid
    @summary[:default_key] = 'uid'
    @fields << :uid
    a.each.with_index{|x,i| x << (i+1).to_s}    
  end

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

    record = make_record(raw_params)
    @doc.root.element('records').add record            

  end

  def capture_fields(params)
    fields = Hash[@fields.map {|x| [x,nil]}]
    fields.keys.each {|key| fields[key] = params[key.to_sym] if params.has_key? key.to_sym}      
    fields
  end
  
  def display_xml(options={})

    opt = {unescape_html: false}.merge options
    load_records if @dirty_flag == true
    doc = rebuild_doc(:external)
    if opt[:unescape_html] == true then
      doc.content(opt) #jr230711 pretty: true
    else
      doc.xml(opt) #jr230711 pretty: true      
    end
  end

  def make_record(raw_params)

    id = (@doc.root.xpath('max(records/*/attribute::id)') || '0').succ unless id
    raw_params.merge!(uid: id) if @default_key == :uid
    params = Hash[raw_params.keys.map(&:to_sym).zip(raw_params.values)]

    fields = capture_fields(params)    
    record = Rexle::Element.new @record_name

    fields.each do |k,v|
      element = Rexle::Element.new(k.to_s)              
      element.root.text = v.to_s.gsub('<','&lt;').gsub('>','&gt;') if v
      record.add element if record
    end
    


    attributes = {id: id.to_s, created: Time.now.to_s, last_modified: nil}
    attributes.each {|k,v| record.add_attribute(k, v)}

    record
  end

  alias refresh_doc display_xml

  def string_parse(buffer)

    buffer.gsub!("\r",'')
    buffer.gsub!(/\n-{4,}\n/,"\n\n")
    buffer.gsub!(/---\n/m, "--- ")

    buffer.gsub!(/.>/) {|x| x[0] != '?' ? x.sub(/>/,'&gt;') : x }
    buffer.gsub!(/<./) {|x| x[1] != '?' ? x.sub(/</,'&lt;') : x }

    @raw_header = buffer[/<\?dynarex[^>]+>/]

    if buffer[/<\?/] then

      raw_stylesheet = buffer.slice!(/<\?xml-stylesheet[^>]+>/)
      @xslt = raw_stylesheet[/href=["']([^"']+)/,1] if raw_stylesheet
      @raw_header = buffer.slice!(/<\?dynarex[^>]+>/) + "\n"

      header = @raw_header[/<?dynarex (.*)?>/,1]

      r1 = /([\w\-]+\s*\=\s*'[^']*)'/
      r2 = /([\w\-]+\s*\=\s*"[^"]*)"/

      r = header.scan(/#{r1}|#{r2}/).map(&:compact).flatten      
      r.each do |x|
        attr, val = x.split(/\s*=\s*["']/,2)
        self.method((attr + '=').to_sym).call(unescape val)
      end

    end

    # if records already exist find the max id
    i = @doc.root.xpath('max(records/*/attribute::id)').to_i
    
    raw_summary = schema[/\[([^\]]+)/,1]
    #rowx = buffer[/--\+.*/m]

    #buffer = rowx if rowx
    
    #jr061013 raw_lines = buffer.gsub(/^\s*#[^\n]+/,'').lines.to_a
    raw_lines = buffer.lines.to_a

    if raw_summary then

      a_summary = raw_summary.split(',').map(&:strip)
      
      @summary ||= {}
      raw_lines.shift while raw_lines.first.strip.empty?

      # fetch any summary lines
      while not raw_lines.empty? and \
          raw_lines.first[/#{a_summary.join('|')}:\s+\S+/] do

        label, val = raw_lines.shift.chomp.match(/(\w+):\s+([^$]+)$/).captures
        @summary[label.to_sym] = val
      end

      self.xslt = @summary[:xslt] || @summary[:xsl] if @summary[:xslt]\
                                                             or @summary[:xsl]
    end


    if @type == 'checklist' then
      
      # extract the brackets from the line

      checked = []
      raw_lines.map! do |x| 
        raw_checked, raw_line = x.partition(/\]/).values_at 0,2
        checked << (raw_checked[/x/] ? true : false)
        raw_line
      end

    end
    
    if @order == 'descending' then
      rl = raw_lines

      if rl.first =~ /--/ then
        raw_lines = [rl[0]] + rl[1..-1].each_slice(@fields.count).inject([])\
            {|r,x| r += x.reverse }.reverse
      else
        raw_lines = rl.each_slice(@fields.count).inject([])\
            {|r,x| r += x.reverse }.reverse
      end
      checked.reverse! if @type == 'checklist'
      
    end    

    @summary[:recordx_type] = 'dynarex'
    @summary[:schema] = @schema
    @summary[:format_mask] = @format_mask
       
    raw_lines.shift while raw_lines.first.strip.empty?

    lines = case raw_lines.first.chomp
      
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

        self.summary[:rawdoc_type] = 'rowx'
        raw_lines.shift

        a3 = raw_lines.join.strip.split(/\n\n(?=\w+:)/)

        # get the fields
        a4 = a3.map{|x| x.scan(/\w+(?=:)/)}.flatten(1).uniq
        a5 = a3.map do |xlines|

          missing_fields = a4 - xlines.scan(/^\w+(?=:)/)
          #r061013 r = xlines.lines.map(&:strip)
          r = xlines.split(/\n(\w+:.*)/)
          r += missing_fields.map{|x| x + ":"}
          r.sort.join("\n")

        end        

        xml = RowX.new(a5.join("\n").strip).to_xml

        a2 = Rexle.new(xml).root.xpath('item').inject([]) do |r,x|          
          r << @fields.map do |field| 
            x.text(a4.all? {|x| x.length > 1} ? field.to_s : field.to_s.chr) 
          end
        end

        a2.compact!        
          
        # if there is no field value for the first field then 
        #   the default_key is invalid. The default_key is changed to an ID.
        if a2.detect {|x| x.first == ''} then
          add_id(a2)
        else

          a3 = a2.map(&:first)
          add_id(a2) if a3 != a3.uniq 
          
        end
        
        a2
        
    else

    raw_lines = raw_lines.join("\n").gsub(/^\s*#[^\n]+/,'').lines.to_a        
      a2 = raw_lines.map.with_index do |x,i|

        next if x[/^\s+$|\n\s*#/]
        
        begin
          
          field_names, field_values = RXRawLineParser.new(@format_mask).parse(x)
        rescue
          raise "input file parser error at line " + (i + 1).to_s + ' --> ' + x
        end
        field_values
      end
      
      a2.compact!
      a3 = a2.compact.map(&:first)
      add_id(a2) if a3 != a3.uniq 

      a2
    end

    a = lines.map.with_index do |x,i| 
      created = Time.now.to_s

      h = Hash[
        @fields.zip(
          x.map do |t|
            
            t.to_s[/^---(?:\s|\n)/] ? YAML.load(t[/^---(?:\s|\n)(.*)/,1]) : unescape(t.to_s)
          end
        )
      ]
      h[@fields.last] = checked[i].to_s if @type == 'checklist'
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
    @flat_records = @flat_records.take @limit_by if @limit_by

    rebuild_doc
    self
  end

  def unescape(s)
    s.gsub('&lt;', '<').gsub('&gt;','>')
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
  
  def openx(s)

    if s[/</] then # xml

      buffer = s
    elsif s[/[\[\(]/] # schema
      dynarex_new(s)
    elsif s[/^https?:\/\//] then  # url
      buffer = Kernel.open(s, 'UserAgent' => 'Dynarex-Reader'){|x| x.read}
    else # local file
      @local_filepath = s
      buffer = File.open(s,'r').read
    end

    if buffer then
      raw_stylesheet = buffer.slice!(/<\?xml-stylesheet[^>]+>/)
      @xslt = raw_stylesheet[/href=["']([^"']+)/,1] if raw_stylesheet
      
      @doc = Rexle.new(buffer) unless @doc      
    end
    
    @schema = @doc.root.text('summary/schema')
    @root_name = @doc.root.name
    @summary = summary_to_h

    @order = @summary[:order] if @summary.has_key? :order

    @default_key = @doc.root.element('summary/default_key/text()') 
    @format_mask = @doc.root.element('summary/format_mask/text()')
   
    @fields = @schema[/([^(]+)\)$/,1].split(/\s*,\s*/).map(&:to_sym)
 
    @fields << @default_key if @default_key and \
                        !@fields.include? @default_key.to_sym

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
    
    @summary[:default_key] = @default_key.to_s

    if @doc.root.xpath('records/*').length > 0 then
      @record_name = @doc.root.element('records/*[1]').name            
      #jr240913 load_records
      @dirty_flag = true
    end

  end  

  def load_records

    @records = records_to_h

    @records = @records.take @limit_by if @limit_by
    
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
 
  def records_to_h(state=:ascending)

    i = @doc.root.xpath('max(records/*/attribute::id)') || 0
    #jr090813 fields = @doc.root.text('summary/schema')[/\(.*\)/].scan(/\w+/)
    records = @doc.root.xpath('records/*')

    recs = (state == :descending ? records.reverse : records)
    a = recs.inject({}) do |result,row|

      created = Time.now.to_s
      last_modified = ''

      if row.attributes[:id] then
        id = row.attributes[:id]
      else
        i += 1; id = i.to_s
      end

      created = row.attributes[:created] if row.attributes[:created]
      last_modified = row.attributes[:last_modified] if row.attributes[:last_modified]

      body = @fields.inject({}) do |r,field|
        
        node = row.element field.to_s

        if node then
          text = node.text ? node.text.unescape : ''

          r.merge node.name.to_sym => (text[/^---(?:\s|\n)/] ? YAML.load(text[/^---(?:\s|\n)(.*)/,1]) : text)
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
