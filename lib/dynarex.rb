#!/usr/bin/ruby

require 'rexml/document'
require 'open-uri'

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

  private

  def open(location)
    if location[/^https?:\/\//] then
      buffer = Kernel.open(location, 'UserAgent' => 'Dynarex-Reader').read
    else
      buffer = File.open(location,'r').read
    end
    @doc = Document.new buffer
    @summary = summary_to_h
    @records = records_to_h
  end

  def display()
    puts @doc.to_s
  end

  def records_to_h
    XPath.match(@doc.root, 'records/*').map do |row|
      XPath.match(row, '*').inject({}) do |r,node|
        r[node.name.to_s.to_sym] = node.text.to_s
        r
      end
    end
  end

  def summary_to_h
    XPath.match(@doc.root, 'summary/*').inject({}) do |r,node|
      r[node.name.to_s.to_sym] = node.text.to_s
      r
    end
  end

end
