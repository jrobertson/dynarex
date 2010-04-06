#!/usr/bin/ruby

require 'rexml/document'
require 'open-uri'
require 'builder'

class Dynarex
  include REXML 

  def initialize(opt)
    o = {xml: '', default_key: ''}.merge opt
    location = o[:xml]
    @default_key = o[:default_key]
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
    @summary = summary_to_h 
    @records = records_to_h @default_key
    @root_name = @doc.root.name
    @item_name = XPath.first(@doc.root, 'records/*[1]').name    
  end  

  def display()
    puts @doc.to_s
  end

  def records_to_h(default_key)
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
      [body[default_key.to_sym],{id: id, created: created, last_modified: \
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
