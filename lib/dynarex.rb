#!/usr/bin/ruby

# file: dynarex.rb

require 'rexml/document'
require 'nokogiri'
require 'open-uri'
require 'builder'

class Dynarex
  include REXML 

  def initialize(location)
    open(location)
  end

  def summary
    @summary
  end

  def records
    @records
  end
  
  def flat_records
    @flat_records
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
  
  def save(filepath)    
    xml = display_xml()
    File.open(filepath,'w'){|f| f.write xml}
  end
  
  def parse(buffer)
    i = XPath.match(@doc.root, 'records/*/attribute::id').max_by(&:value).to_s.to_i
    format_mask = XPath.first(@doc.root, 'summary/format_mask/text()').to_s
    t = format_mask.to_s.gsub(/\[!(\w+)\]/, '(.*)').sub(/\[/,'\[').sub(/\]/,'\]')
    lines = buffer.split(/\r?\n|\r(?!\n)/).map {|x|x.match(/#{t}/).captures}
    fields = format_mask.scan(/\[!(\w+)\]/).flatten.map(&:to_sym)
    
    a = lines.map do|x| 
      created = Time.now.to_s
      
      h = Hash[fields.zip(x)]
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

  def create(params={})

    record_name, fields = capture_fields(params)
    record = Element.new record_name
    fields.each{|k,v| record.add Element.new(k.to_s).add_text(v) if v}

    ids = XPath.match(@doc.root,'records/*/attribute::id').map &:value
    id = ids.empty? ? 1 : ids.max.succ

    attributes = {id: id, created: Time.now.to_s, last_modified: nil}
    attributes.each {|k,v| record.add_attribute(k.to_s, v)}
    @doc.root.elements['records'].add record  

    load_records
  end

  def update(id, params={})
    record_name, fields = capture_fields(params)
    
    # for each field update each record field
    record = XPath.first(@doc.root, "records/#{record_name}[@id=#{id.to_s}]")
    fields.each {|k,v| record.elements[k.to_s].text = v if v}
    load_records
  end

  def delete(id)        
    node = XPath.first(@doc.root, "records/*[@id='#{id}']")
    node.parent.delete node        
    load_records
  end

  private

  def capture_fields(params)

    record_name, raw_fields = @schema.match(/(\w+)\(([^\)]+)/).captures
    fields = Hash[raw_fields.split(',').map{|x| [x.strip.to_sym, nil]}]

    fields.keys.each {|key| fields[key] = params[key] if params.has_key? key}      
    [record_name, fields]
  end

  
  def display_xml
    
    xml = Builder::XmlMarkup.new( :target => buffer='', :indent => 2 )
    xml.instruct! :xml, :version => "1.0", :encoding => "UTF-8"

    xml.send @root_name do
      xml.summary do
        @summary.each{|key,value| xml.send key, value}
      end
      xml.records do
        @records.each do |k, item|
          xml.send(@item_name, id: item[:id], created: item[:created], \
              last_modified: item[:last_modified]) do
            item[:body].each{|name,value| xml.send name, value}
          end
        end
      end
    end

    buffer

  end

  def open(location)
    if location[/^https?:\/\//] then
      buffer = Kernel.open(location, 'UserAgent' => 'Dynarex-Reader').read
    elsif location[/\</]
      buffer = location
    else
      buffer = File.open(location,'r').read
    end
    @doc = Document.new buffer
    @default_key = (XPath.first(@doc.root, 'summary/default_key/text()') || \
        XPath.first(@doc.root, 'records/*[1]/*[1]').name).to_s.to_sym

    @summary = summary_to_h    
    @schema = @doc.root.text('summary/schema').to_s
    load_records
    @root_name = @doc.root.name
    @item_name = XPath.first(@doc.root, 'records/*[1]').name    
  end  

  def load_records
    @records = records_to_h
    @flat_records = flat_records_to_h
  end

  def display()
    puts @doc.to_s
  end

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

