#!/usr/bin/env ruby

# file: dynarex.rb

require 'open-uri'
require 'dynarex-import'
#require 'line-tree'
#require 'rexle'
require 'rexle-builder'
require 'rexslt'
require 'dynarex-xslt'
require 'recordx'
require 'rxraw-lineparser'
require 'yaml'
require 'rowx'
require 'ostruct'
require 'table-formatter'
require 'rxfreader'
require 'kvx'
require 'json'


module RegGem

  def self.register()
'
hkey_gems
  doctype
    dynarex
      require dynarex
      class Dynarex
      media_type dynarex
'
  end
end


class DynarexException < Exception
end

class DynarexRecordset < Array

  def initialize(a, caller=nil)
    super(a)
    @caller = caller
  end

  def reject!()

    a = self.to_a.clone
    a2 = super
    return nil unless a2
    a3 = a - a2

    @caller.delete  a3.map(&:id)
    self
  end

  def sum(field)
    self.inject(0) {|r, x| r + x[field.to_sym][/\d+(\.\d+)?$/].to_f }
  end

  def index(val)
    self.map(&:to_h).index val.to_h
  end

  def index_by_id(id)
    self.map(&:id).index id
  end

end


class Dynarex
  include RXFReadWriteModule
  using ColouredText

  attr_accessor :format_mask, :delimiter, :xslt_schema, :schema, :linked,
      :order, :type, :limit, :xslt, :json_out, :unique


#Create a new dynarex document from 1 of the following options:
#* a local file path
#* a URL
#* a schema string
#    Dynarex.new 'contacts[title,description]/contact(name,age,dob)'
#* an XML string
#    Dynarex.new '<contacts><summary><schema>contacts/contact(name,age,dob)</schema></summary><records/></contacts>'

  def initialize(rawx=nil, username: nil, password: nil, schema: nil,
              default_key: nil, json_out: true, debug: false,
                 delimiter: ' # ', autosave: false, order: 'ascending',
                 unique: false, filepath: nil)


    puts 'inside Dynarex::initialize' if debug
    @username, @password, @schema,  = username,  password, schema
    @default_key, @json_out, @debug = default_key, json_out, debug
    @autosave, @unique = autosave, unique
    @local_filepath = filepath

    puts ('@debug: ' + @debug.inspect).debug if debug
    @delimiter = delimiter
    @spaces_delimited = false
    @order = order
    @limit = nil
    @records, @flat_records = [], []
    rawx ||= schema if schema

    if rawx then

      return import(rawx) if rawx =~ /\.txt$/
      openx(rawx.clone)

    end

    self.order = @order unless @order.to_sym == :ascending

  end

  def add(x)
    @doc.root.add x
    @dirty_flag = true
    self
  end

  def all()

    refresh! if @dirty_flag
    a = @doc.root.xpath("records/*").map {|x| recordx_to_record x}
    DynarexRecordset.new(a, self)

  end

  def clone()
    Dynarex.new(self.to_xml)
  end

  def default_key()
    self.summary[:default_key]
  end

  def delimiter=(separator)

    if separator == :spaces then
      @spaces_delimited = true
      separator = ' # '
    end

    @delimiter = separator

    if separator.length > 0 then
      @summary[:delimiter] = separator
    else
      @summary.delete :delimiter
    end

    @format_mask = @format_mask.to_s.gsub(/\s/, separator)
    @summary[:format_mask] = @format_mask
  end

  def doc
    (load_records; rebuild_doc) if @dirty_flag == true
    @doc
  end

  # XML import
  #
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

  def first
    r = @doc.root.element("records/*")
    r ? recordx_to_record(r) : nil
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

  def linked=(bool)
    @linked = bool == 'true'
  end

  def order=(value)

    self.summary.merge!({order: value.to_s})

    @order = value.to_s
  end

  def recordx_type()
    @summary[:recordx_type]
  end

  def schema=(s)
    openx s
  end

  def type=(v)
    @order = 'descending' if v == 'feed'
    @type = v
    @summary[:type] = v
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
  def flat_records(select: nil)

    fields = select

    load_records if @dirty_flag == true

    if fields then

      case fields.class.to_s.downcase.to_sym
      when :string
        field = fields.to_sym
        @flat_records.map {|row| {field => row[field]}}
      when :symbol
        field = fields.to_sym
        @flat_records.map {|row| {field => row[field]} }
      when :array
        @flat_records.map {|row| fields.inject({})\
                           {|r,x| r.merge(x.to_sym => row[x.to_sym])}}
      end

    else
      @flat_records
    end

  end

  alias to_a flat_records

  # Returns an array snapshot of OpenStruct records
  #
  def ro_records
    flat_records.map {|record| OpenStruct.new record }
  end

  def rm(force: false)

    if force or all.empty? then
      FileX.rm @local_filepath if @local_filepath
      'file ' + @local_filepath + ' deleted'
    else
      'unable to rm file: document not empty'
    end

  end


  def to_doc
    self.clone().doc
  end

  # Typically uses the 1st field as a key and the remaining fields as the value
  #
  def to_h()

    key = self.default_key.to_sym
    fields = self.fields() - [key]
    puts 'fields: ' + fields.inspect if @debug

    flat_records.inject({}) do |r, h|

      puts 'h: ' + h.inspect if @debug

      value = if h.length == 2 then
        h[fields[0]].to_s
      else
        fields.map {|x| h[x]}
      end

      r.merge(h[key] => value)
    end

  end

  def to_html(domain: '')

    h = {username: @username, password: @password}
    xsl_buffer = RXFReader.read(domain + @xslt, h).first
    Rexslt.new(xsl_buffer, self.to_doc).to_s

  end


  # to_json: pretty is set to true because although the file size is larger,
  # the file can be load slightly quicker

  def to_json(pretty: true)

    records = self.to_a
    summary = self.summary.to_h

    root_name = schema()[/^\w+/]
    record_name = schema()[/(?<=\/)[^\(]+/]

    h = {
      root_name.to_sym =>
      {
        summary: @summary,
        records: @records.map {|_, h| {record_name.to_sym => h} }
      }
    }

    pretty ? JSON.pretty_generate(h) : h.to_json

  end

  def to_s(header: true, delimiter: @delimiter)

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


    raw_summary_fields = self.summary[:schema][/^\w+\[([^\]]+)\]/,1]
    sumry = ''

    if raw_summary_fields then
      summary_fields = raw_summary_fields.split(',') # .map(&:to_sym)
      sumry = summary_fields.map {|x| x.strip!; x + ': ' + \
                               self.summary[x.to_sym].to_s}.join("\n") + "\n\n"
    end

    if @raw_header then
      declaration = @raw_header
    else

      smry_fields = %i(schema)
      smry_fields << :order if self.summary[:order] == 'descending'

      if delimiter.length > 0 then
        smry_fields << :delimiter
      else
        smry_fields << :format_mask unless self.summary[:rawdoc_type] == 'rowx'
      end
      s = smry_fields.map {|x| "%s=\"%s\"" % \
        [x, self.send(x).gsub('"', '\"') ]}.join ' '

      declaration = %Q(<?dynarex %s?>\n) % s
    end

    docheader = declaration + sumry

    if self.summary[:rawdoc_type] == 'rowx' then
      a = self.fields.map do |field|
  "<xsl:if test=\"%s != ''\">
<xsl:text>\n</xsl:text>%s:<xsl:text> </xsl:text><xsl:value-of select='%s'/>
  </xsl:if>" % ([field]*3)
      end

      puts ('a: ' + a.inspect).debug if @debug

      xslt_format = a.join

      xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)

      if @debug then
        File.write '/tmp/foo.xsl', xsl_buffer
        File.write '/tmp/foo.xml', @doc.xml
        puts 'xsl_buffer: ' + xsl_buffer.inspect
      end

      out = Rexslt.new(xsl_buffer, @doc).to_s

      docheader + "\n--+\n" + out
    elsif self.summary[:rawdoc_type] == 'sectionx' then

      a = (self.fields - [:uid, 'uid']).map do |field|
  "<xsl:if test=\"%s != ''\">
<xsl:text>\n</xsl:text><xsl:value-of select='%s'/>
  </xsl:if>" % ([field]*2)
      end

      xslt_format = a.join

      xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)
      puts 'xsl_buffer: ' + xsl_buffer.inspect if @debug

      out = Rexslt.new(xsl_buffer, @doc).to_s

      header ? docheader + "--#\n" + out : out

    elsif self.delimiter.length > 0 then
      puts 'dinddd'
      tfo = TableFormatter.new border: false, wrap: false, \
                                                  divider: self.delimiter
      tfo.source = self.to_a.map{|x| x.values}
      docheader + tfo.display.strip

    else

      format_mask = self.format_mask
      format_mask.gsub!(/\[[^!\]]+\]/) {|x| x[1] }

      s1, s2 = '<xsl:text>', '</xsl:text>'
      xslt_format = s1 + format_mask\
          .gsub(/(?:\[!(\w+)\])/, s2 + '<xsl:value-of select="\1"/>' + s1) + s2

      xsl_buffer.sub!(/\[!regex_values\]/, xslt_format)

      puts 'xsl_buffer: ' + xsl_buffer if @debug
      out = Rexslt.new(xsl_buffer, @doc).to_s

      header ? docheader + "\n" + out : out
    end

  end

  def to_table(fields: nil, markdown: false, innermarkdown: false, heading: true)

    tfo = TableFormatter.new markdown: markdown, innermarkdown: innermarkdown
    tfo.source = self.to_a.map {|h| fields ? fields.map {|x| h[x]} : h.values }

    if heading then
      raw_headings = self.summary[:headings]
      fields = raw_headings.split(self.delimiter) if raw_headings and fields.nil?
      tfo.labels = (fields ? fields : self.fields.map{|x| x.to_s.capitalize })
    end

    tfo

  end

  def to_xml(opt={})
    opt = {pretty: true} if opt == :pretty
    display_xml(opt)
  end

# Save the document to a file.

  def save(filepath=@local_filepath, options={})

    if @debug then
      puts 'inside Dynarex::save'
      puts 'filepath: '  + filepath.inspect

    end

    return unless filepath

    opt = {pretty: true}.merge options

    @local_filepath = filepath || 'dx.xml'
    xml = display_xml(opt)
    buffer = block_given? ? yield(xml) : xml

    if @debug then
      puts 'before write; filepath: ' + filepath.inspect
      puts 'buffer: ' + buffer.inspect
    end

    FileX.write filepath, buffer
    FileX.write(filepath.sub(/\.xml$/,'.json'), self.to_json) if @json_out
  end

#Parses 1 or more lines of text to create or update existing records.

  def parse(x=nil)

    @dirty_flag = true

    if x.is_a? Array then

      unless @schema then
        cols = x.first.keys.map {|c| c == 'id' ? 'uid' : c}
        self.schema = "items/item(%s)" % cols.join(', ')
      end

      x.each {|record| self.create record }
      return self

    end
    raw_buffer, type = RXFReader.read(x, auto: false)

    if raw_buffer.is_a? String then

      buffer = block_given? ? yield(raw_buffer) : raw_buffer.clone
      string_parse buffer.force_encoding('UTF-8')

    else
      foreign_import x
    end

  end


  alias import parse

#Create a record from a hash containing the field name, and the field value.
#  dynarex = Dynarex.new 'contacts/contact(name,age,dob)'
#  dynarex.create name: Bob, age: 52

  def create(obj, id: nil, custom_attributes: {})

    puts 'inside create' if @debug
    raise 'Dynarex#create(): input error: no arg provided' unless obj

    case obj.class.to_s.downcase.to_sym
    when :hash
      hash_create  obj, id, attr: custom_attributes
    when :string
      create_from_line obj, id, attr: custom_attributes
    when :recordx
      hash_create  obj.to_h, id || obj.id, attr: custom_attributes
    else
      hash_create  obj.to_h, id, attr: custom_attributes
    end

    @dirty_flag = true

    puts 'before save ' + @autosave.inspect if @debug
    save() if @autosave

    self
  end

#Create a record from a string, given the dynarex document contains a format mask.
#  dynarex = Dynarex.new 'contacts/contact(name,age,dob)'
#  dynarex.create_from_line 'Tracy 37 15-Jun-1972'

  def create_from_line(line, id=nil, attr: '')
    t = @format_mask.to_s.gsub(/\[!(\w+)\]/, '(.*)').sub(/\[/,'\[')\
                                                                .sub(/\]/,'\]')
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

  def update(id, obj)

    params = if obj.is_a? Hash then
      obj
    elsif obj.is_a? RecordX
      obj.to_h
    end

    fields = capture_fields(params)

    # for each field update each record field
    record = @doc.root.element("records/#{@record_name}[@id='#{id.to_s}']")

    fields.each do |k,v|
      puts "updating ... %s = '%s'" % [k,v] if @debug
      record.element(k.to_s).text = v if v
    end

    record.add_attribute(last_modified: Time.now.to_s)

    @dirty_flag = true

    save() if @autosave

    self

  end


#Delete a record.
#  dyarex.delete 3      # deletes record with id 3

  def delete(x)

    return x.each {|id| self.delete id} if x.is_a? Array

    if x.to_i.to_s == x.to_s and x[/[0-9]/] then
      @doc.root.delete("records/*[@id='#{x}']")
    else
      @doc.delete x
    end

    @dirty_flag = true
    save() if @autosave

    self
  end

  def element(x)
    @doc.root.element x
  end

  def sort_by!(field=nil, &element_blk)

    blk = field ? ->(x){ x.text(field.to_s).to_s} : element_blk
    r = sort_records_by! &blk
    @dirty_flag = true
    r

  end


  def record(id)
    e = @doc.root.element("records/*[@id='#{id}']")
    recordx_to_record e if e
  end

  alias find record
  alias find_by_id record

  def record_exists?(id)
    !@doc.root.element("records/*[@id='#{id}']").nil?
  end

  def refresh()
    @dirty_flag = true
  end

  def refresh!()
    (load_records; rebuild_doc) if @dirty_flag == true
  end

  # used internally by to_rss()
  #
  def rss_xslt(opt={})

    h = {limit: 11}.merge(opt)
    doc = Rexle.new(self.to_xslt)
    e = doc.element('//xsl:apply-templates[2]')

    e2 = doc.root.element('xsl:template[3]')
    item = e2.element('item')
    new_item = item.deep_clone
    item.delete

    pubdate = @xslt_schema[/pubDate:/]
    xslif = Rexle.new("<xsl:if test='position() &lt; #{h[:limit]}'/>").root

    if pubdate.nil? then
      pubdate = Rexle.new("<pubDate><xsl:value-of select='pubDate'>" + \
                              "</xsl:value-of></pubDate>").root
      new_item.add pubdate
    end

    xslif.add new_item
    e2.add xslif.root
    xslt = doc.xml

    xslt

  end

  def filter(&blk)

    dx = Dynarex.new @schema
    self.all.select(&blk).each {|x| dx.create x}
    dx

  end

  def to_xslt(opt={})

    h = {limit: -1}.merge(opt)
    @xslt_schema = @xslt_schema || self.summary[:xslt_schema]
    raise 'to_xslt(): xslt_schema nil' unless @xslt_schema

    xslt = DynarexXSLT.new(schema: @schema, xslt_schema: @xslt_schema ).to_xslt

    return xslt
  end

  def to_rss(opt={}, xslt=nil)

    puts 'inside to_rss'.info if @debug

    unless xslt then

      h = {limit: 11}.merge(opt)
      doc = Rexle.new(self.to_xslt)
      e = doc.element('//xsl:apply-templates[2]')

      e2 = doc.root.element('xsl:template[3]')
      item = e2.element('item')
      new_item = item.deep_clone
      item.delete

      pubdate = @xslt_schema[/pubDate:/]
      xslif = Rexle.new("<xsl:if test='position() &lt; #{h[:limit]}'/>").root


      if pubdate.nil? then
        pubdate2 = Rexle.new("<pubDate><xsl:value-of select='pubDate'></xsl:value-of></pubDate>").root
        new_item.add pubdate2
      end

      xslif.add new_item
      e2.add xslif
      xslt = doc.xml

      xslt
    end

    doc = Rexle.new(self.to_xml)

    puts ('pubdate: ' + pubdate.inspect).debug if @debug

    if pubdate.nil? then
      doc.root.xpath('records/*').each do |x|
        raw_dt = DateTime.parse x.attributes[:created]
        dt = raw_dt.strftime("%a, %d %b %Y %H:%M:%S %z")
        x.add Rexle::Element.new('pubDate').add_text dt.to_s
      end
    end

    puts ('doc: ' + doc.root.xml) if @debug
    File.write '/tmp/blog.xml', doc.root.xml
    puts ('xslt:'  + xslt.inspect) if @debug
    File.write '/tmp/blog.xslt', xslt

    out = Rexslt.new(xslt, doc).to_s(declaration: false)

    #Rexle.new("<rss version='2.0'>%s</rss>" % xml).xml(pretty: true)

    doc = Rexle.new("<rss version='2.0'>%s</rss>" % out.to_s)
    yield( doc ) if block_given?
    xml = doc.xml(pretty: true)
    xml
  end

  def unique=(bool)
    self.summary.merge!({unique: bool})
    @dirty_flag = true
    @unique = bool
  end

  def xpath(x)
    @doc.root.xpath x
  end

  def xslt=(value)

    self.summary.merge!({xslt: value})
    @dirty_flag = true
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
        "def find_all_by_#{field}(value) findx_all_by(\"#{field}\", value) end"
    end
    self.instance_eval(methods.join("\n"))
  end

  def findx_by(field, value)

    #@logger.debug "field: #{field.inspect}, value: #{value.inspect}"
    (load_records; rebuild_doc) if @dirty_flag == true

    if value.is_a? String then

      r = @doc.root.element("records/*[#{field}=\"#{value}\"]")
      r ? recordx_to_record(r) : nil

    elsif value.is_a? Regexp

      found = all.select {|x| x.method(field).call =~ /#{value}/i}
      found.first if found.any?

    end

  end

  def findx_all_by(field, value)

    if value.is_a? String then

      @doc.root.xpath("records/*[#{field}=\"#{value}\"]")\
                                             .map {|x| recordx_to_record x}

    elsif value.is_a? Regexp

      all.select {|x| x.method(field).call =~ /#{value}/i}

    end
  end

  def recordx_to_record(recordx)

    h = recordx.attributes

    records = recordx.xpath("*").map {|x|  x.text ? x.text.unescape.to_s : '' }
    hash = @fields.zip(records).to_h
    RecordX.new(hash, self, h[:id], h[:created], h[:last_modified])

  end

  def hash_create(raw_params={}, id=nil, attr: {})

    puts 'inside hash_create' if @debug
    record = make_record(raw_params, id, attr: attr)
    puts 'record: '  + record.inspect if @debug
    method_name = @order == 'ascending' ? :add : :prepend
    @doc.root.element('records').method(method_name).call record

  end

  def capture_fields(params)
    fields = Hash[@fields.map {|x| [x,nil]}]
    fields.keys.each {|key| fields[key] = params[key.to_sym] if params.has_key? key.to_sym}
    fields
  end

  def display_xml(options={})
    #@logger.debug 'inside display_xml'
    opt = {unescape_html: false}.merge options

    state = :external
    #@logger.debug 'before diry'
    if @dirty_flag == true then
      load_records
      state = :internal
    end
    #@logger.debug 'before rebuilt'
    doc = rebuild_doc(state)
    #@logger.debug 'after rebuild_doc'

    if opt[:unescape_html] == true then
      doc.content(opt)
    else
      doc.xml(opt)
    end
  end

  def make_record(raw_params, id=nil, attr: {})

    id = (@doc.root.xpath('max(records/*/attribute::id)') || '0').succ unless id
    raw_params.merge!(uid: id) if @default_key.to_sym == :uid
    params = Hash[raw_params.keys.map(&:to_sym).zip(raw_params.values)]

    fields = capture_fields(params)
    record = Rexle::Element.new @record_name

    fields.each do |k,v|
      element = Rexle::Element.new(k.to_s)
      element.root.text = v.to_s.gsub('<','&lt;').gsub('>','&gt;') if v
      record.add element if record
    end

    attributes = {id: id.to_s, created: Time.now.to_s, last_modified: nil}\
                                                                  .merge attr
    attributes.each {|k,v| record.add_attribute(k, v)}

    record
  end

  alias refresh_doc display_xml

  def parse_links(raw_lines)

    raw_lines.map do |line|

      buffer = RXFReader.read(line.chomp, auto: false).first

      doc = Rexle.new buffer

      if doc.root.name == 'kvx' then

        kvx = Kvx.new doc
        h = kvx.to_h[:body]
        @fields.inject([]){|r,x| r << h[x]}

      end

    end

  end

  def rebuild_doc(state=:internal)

    puts 'inside rebuild_doc'.info if @debug

    reserved_keywords = (
                          Object.public_methods | \
                          Kernel.public_methods | \
                          public_methods + [:method_missing]
                        )

    xml = RexleBuilder.new

    a = xml.send @root_name do

      xml.summary do

        @summary.each do |key,value|

          v = value.to_s.gsub('>','&gt;')\
            .gsub('<','&lt;')\
            .gsub(/(&\s|&[a-zA-Z\.]+;?)/) {|x| x[-1] == ';' ? x \
                                                      : x.sub('&','&amp;')}

          xml.send key, v

        end
      end

      records = @records.to_a

      if records then

        #jr160315records.reverse! if @order == 'descending' and state == :external

        xml.records do

          records.each do |k, item|

            attributes = {}

            item.keys.each do |key|
              attributes[key] = item[key] || '' unless key == :body
            end

            if @record_name.nil? then
              raise DynarexException, 'record_name can\'t be nil. Check the schema'
            end

            puts 'attributes: ' + attributes.inspect if @debug
            puts '@record_name: ' + @record_name.inspect if @debug

            xml.send(@record_name, attributes) do
              item[:body].each do |name,value|

                if reserved_keywords.include? name then
                  name = ('._' + name.to_s).to_sym
                end

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

    puts ('@xslt: ' + @xslt.inspect).debug if @debug

    if @xslt then
      doc.instructions = [['xml-stylesheet',
        "title='XSL_formatting' type='text/xsl' href='#{@xslt}'"]]
    end

    return doc if state != :internal
    @doc = doc
  end

  def string_parse(buffer)

    if @spaces_delimited then
      buffer = buffer.lines.map{|x| x.gsub(/\s{2,}/,' # ')}.join
    end

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
        name = (attr + '=').to_sym

        if self.public_methods.include? name then
          self.method(name).call(unescape val)
        else
          puts "Dynarex: warning: method %s doesn't exist." % [name.inspect]
        end
      end

    end

    # if records already exist find the max id
    i = @doc.root.xpath('max(records/*/attribute::id)').to_i

    raw_summary = schema[/\[([^\]]+)/,1]

    raw_lines = buffer.lines.to_a

    if raw_summary then

      a_summary = raw_summary.split(',').map(&:strip)

      @summary ||= {}
      raw_lines.shift while raw_lines.first.strip.empty?

      # fetch any summary lines
      while not raw_lines.empty? and \
          raw_lines.first[/#{a_summary.join('|')}:\s+\S+/] do

        label, val = raw_lines.shift.chomp.match(/(\w+):\s*([^$]+)$/).captures
        @summary[label.to_sym] = val
      end

      self.xslt = @summary[:xslt] || @summary[:xsl] if @summary[:xslt]\
                                                             or @summary[:xsl]
    end

    @summary[:recordx_type] = 'dynarex'
    @summary[:schema] = @schema
    @summary[:format_mask] = @format_mask
    @summary[:unique] = @unique if @unique

    raw_lines.shift while raw_lines.first.strip.empty?

    lines = case raw_lines.first.rstrip

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

        rowx(raw_lines)

      when '--#'

        self.summary[:rawdoc_type] = 'sectionx'
        raw_lines.shift

        raw_lines.join.lstrip.split(/(?=^#[^#])/).map {|x| [x.rstrip]}

    else

      raw_lines = raw_lines.join("\n").gsub(/^(\s*#[^\n]+|\n)/,'').lines.to_a

      if @linked then

        parse_links(raw_lines)

      else
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

        if a3 != a3.uniq then

          if @unique then
            raise DynarexException, "Duplicate id found"
          else
            add_id(a2)
          end

        end

        a2
      end

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

    @flat_records = @records.values.map{|x| x[:body]}

    rebuild_doc
    self
  end

  def sort_records_by!(&element_blk)

    refresh_doc
    a = @doc.root.xpath('records/*').sort_by &element_blk
    @doc.root.delete('records')

    records = Rexle::Element.new 'records'

    a.each {|record| records.add record}

    @doc.root.add records

    load_records if @dirty_flag
    self
  end

  def unescape(s)
    s.gsub('&lt;', '<').gsub('&gt;','>')
  end

  def dynarex_new(s, default_key: nil)

    @schema = schema = s
    @default_key = default_key if default_key

    ptrn = %r((\w+)\[?([^\]]+)?\]?\/(\w+)\(([^\)]+)\))

    if s.match(ptrn) then

      @root_name, raw_summary, record_name, raw_fields = s.match(ptrn).captures
      reserved = %w(require parent gem)

      raise 'reserved keyword: ' + record_name if reserved.include? record_name
      summary, fields = [raw_summary || '',raw_fields].map {|x| x.split(/,/).map &:strip}

      if fields.include? 'id' then
        raise 'Dynarex#dynarex_new: schema field id is a reserved keyword'
      end

      create_find fields


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
    #@logger.debug 'inside openx'
    if s[/</] then # xml
      #@logger.debug 'regular string'
      #@logger.debug 's: ' + s.inspect
      buffer = s

    elsif s[/[\[\(]/] # schema

      dynarex_new(s)

    elsif s[/^https?:\/\//] then  # url
      buffer, type = RXFReader.read s, {username: @username,
                                     password: @password, auto: false}
    elsif s[/^dfs?:\/\//] then

      @local_filepath = s

      if FileX.exists? s then
        buffer = FileX.read(s).force_encoding("UTF-8")
      elsif @schema
        dynarex_new @schema, default_key: @default_key
      end

    else # local file

      @local_filepath = s

      if File.exists? s then
        buffer = File.read s
      elsif @schema
        dynarex_new @schema, default_key: @default_key
      else
        raise DynarexException, 'file not found: ' + s
      end
    end
    #@logger.debug 'buffer: ' + buffer[0..120]

    return import(buffer) if buffer =~ /^<\?dynarex\b/

    if buffer then

      raw_stylesheet = buffer.slice!(/<\?xml-stylesheet[^>]+>/)
      @xslt = raw_stylesheet[/href=["']([^"']+)/,1] if raw_stylesheet

      @doc = Rexle.new(buffer) unless @doc
      #@logger.debug 'openx/@doc : ' + @doc.xml.inspect
    end

    return if @doc.root.nil?
    e = @doc.root.element('summary')

    @schema = e.text('schema')
    @root_name = @doc.root.name
    @summary = summary_to_h

    summary_methods = (@summary.keys - self.public_methods)

    summary_methods.each do |x|

      instance_eval "

        def #{x.to_sym}()
          @summary[:#{x}]
        end

        def #{x.to_s}=(v)
          @summary[:#{x}] = v
          @doc.root.element('summary/#{x.to_s}').text = v
        end
        "
    end

    @order = @summary[:order] if @summary.has_key? :order


    @default_key ||= e.text('default_key')
    @format_mask = e.text('format_mask')
    @xslt = e.text('xslt')

    @fields = @schema[/([^(]+)\)$/,1].split(/\s*,\s*/).map(&:to_sym)

    @fields << @default_key if @default_key and not @default_key.empty? and \
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

    puts 'inside load_records'.info if @debug

    @dirty_flag = false

    if @summary[:order] then
      orderfield = @summary[:order][/(\w+)\s+(?:ascending|descending)/,1]
      sort_records_by! {|x| x.element(orderfield).text }  if orderfield
    end

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

  def records_to_h(order=:ascending)

    i = @doc.root.xpath('max(records/*/attribute::id)') || 0
    records = @doc.root.xpath('records/*')
    #@logger.debug 'records: ' + records.inspect
    records = records.take @limit if @limit

    recs = records #jr160315 (order == :descending ? records.reverse : records)
    a = recs.inject({}) do |result,row|

      created = Time.now.to_s
      last_modified = ''

      if row.attributes[:id] then
        id = row.attributes[:id]
      else
        i += 1; id = i.to_s
      end

      body = (@fields - ['uid']).inject({}) do |r,field|

        node = row.element field.to_s

        if node then
          text = node.text ? node.text.unescape : ''

          r.merge node.name.to_sym => (text[/^---(?:\s|\n)/] ?
                              YAML.load(text[/^---(?:\s|\n)(.*)/,1]) : text)
        else
          r
        end
      end

      body[:uid] = id if @default_key == 'uid'

      attributes = row.attributes
      result.merge body[@default_key.to_sym] => attributes.merge({id: id, body: body})
    end

    puts 'records_to_h a: ' + a.inspect if @debug
    #@logger.debug 'a: ' + a.inspect
    a

  end

  def rowx(raw_lines)

    self.summary[:rawdoc_type] = 'rowx'
    raw_lines.shift

    a3 = raw_lines.join.strip.split(/\n\n(?=\w+:)/)

    # get the fields
    a4 = a3.map{|x| x.scan(/^\w+(?=:)/)}.flatten(1).uniq

    abbrv_fields = a4.all? {|x| x.length == 1}

    a5 = a3.map do |xlines|

      puts 'xlines: ' + xlines.inspect if @debug

      missing_fields = a4 - xlines.scan(/^\w+(?=:)/)

      r = xlines.split(/\n(\w+:.*)/m)
      puts 'r: ' + r.inspect if @debug

      missing_fields.map!{|x| x + ":"}
      key = (abbrv_fields ? @fields[0].to_s[0] : @fields.first.to_s) + ':'

      if missing_fields.include? key
        r.unshift key
        missing_fields.delete key
      end

      r += missing_fields
      r.join("\n")

    end
    puts 'a5: ' + a5.inspect if @debug

    xml = RowX.new(a5.join("\n").strip, level: 0).to_xml
    puts 'xml: ' + xml.inspect if @debug

    a2 = Rexle.new(xml).root.xpath('item').inject([]) do |r,x|

      r << @fields.map do |field|
        x.text(abbrv_fields ? field.to_s.chr : field.to_s )
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

    h = {recordx_type: 'dynarex'}

    @doc.root.xpath('summary/*').inject(h) do |r,node|
      r.merge node.name.to_s.to_sym =>
            node.text ? node.text.unescape : node.text.to_s
    end
  end

end
