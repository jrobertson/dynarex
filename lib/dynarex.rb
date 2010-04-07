#!/usr/bin/ruby

require 'rexml/document'
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
  
  def to_xml
    display_xml()
  end
  
  def save(filepath)    
    xml = display_xml()
    File.open(filepath,'w'){|f| f.write xml}
  end
  
  def parse(buffer)
    format_mask = XPath.first(@doc.root, 'summary/format_mask/text()').to_s
    t = format_mask.to_s.gsub(/\[!(\w+)\]/, '(.*)').sub(/\[/,'\[').sub(/\]/,'\]')
    lines = buffer.split(/\r?\n|\r(?!\n)/).map {|x|x.match(/#{t}/).captures}
    fields = format_mask.scan(/\[!(\w+)\]/).flatten.map(&:to_sym)
    
    a = lines.each_with_index.map do|x,i| 
      created = Time.now.to_s; id = Time.now.strftime("%Y%m%I%H%M%S") + i.to_s
      h = Hash[fields.zip(x)]
      [h[@default_key], {id: id, created: created, last_modified: '', body: h}]
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

        h[key] = item.clone
      end      
    end    
    
    h.each {|key, item| h.delete(key) if not h2.has_key? key}
    self
  end  

  private
  
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
    @records = records_to_h
    @root_name = @doc.root.name
    @item_name = XPath.first(@doc.root, 'records/*[1]').name    
  end  

  def display()
    puts @doc.to_s
  end

  def records_to_h()
    ah = XPath.match(@doc.root, 'records/*').each_with_index.map do |row,i|
      created = Time.now.to_s; id = Time.now.strftime("%Y%m%I%H%M%S") + i.to_s
      last_modified = ''
      id = row.attribute('id').value.to_s if row.attribute('id')
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
