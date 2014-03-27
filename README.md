# Introducing the Dynarex gem

The Dynarex gem makes it convenient to read Dynarex records as a hash.

## Installation

`sudo gem install dynarex`
<pre>
Successfully installed dynarex-0.1.0
1 gem installed
Installing ri documentation for dynarex-0.1.0...
Updating class cache with 2747 classes...
Installing RDoc documentation for dynarex-0.1.0...
</pre>

## Example

    require 'dynarex'

    url = 'https://dl.dropbox.com/u/709640/scotruby2010-all.xml'
    users = Dynarex.new(url).records

    # display the top 5 twitter users with the most followers
    users.sort_by {|x| -x[:followers_count].to_i}[0..4].each_with_index do |user, i|
      puts "%d %+4s %s" % [i+1, user[:followers_count], user[:twitter_name]]
    end

output:
<pre>
1 8947 timbray
2 2510 jimweirich
3 2228 marick
4 1837 chacon
5 1619 objo
</pre>

Here's the code for the Dynarex class

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
          buffer = Kernel.open(location, 'UserAgent' =&gt; 'Dynarex-Reader').read
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

## Resources

* [Dynarex](http://github.com/jrobertson/Dynarex)

*update: 08-May-2010 @ 10:24pm*

The latest Dynarex gem update means the above code runs as follows:

    users.sort_by {|key,value| -value[:body][:followers_count].to_i}[0..4].each_with_index do |user, i|
      puts "%d %+4s %s" % ([i+1] + [:followers_count, :twitter_name].map {|x| user[1][:body][x]})
    end

*update: 09-May-2010 @ 9:59pm*

The Dynarex gem now supports the method 'flat_record' to return a read-only snapshot of the dynarex records as a simple hash e.g.

    users = Dynarex.new(url).flat_records

    # display the top 5 twitter users with the most followers
    users.sort_by {|x| -x[:followers_count].to_i}[0..4].each_with_index do |user, i|
      puts "%d %+4s %s" % [i+1, user[:followers_count], user[:twitter_name]]
    end

