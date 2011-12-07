require 'thread'
require 'robots'
require 'anemone/tentacle'
require 'anemone/page'
require 'anemone/exceptions'
require 'anemone/page_store'
require 'anemone/storage'
require 'anemone/storage/base'
require 'anemone/queue'

module Anemone

  VERSION = '0.6.1';

  #
  # Convenience method to start a crawl
  #
  def Anemone.crawl(urls, options = {}, &block)
    Core.crawl(urls, options, &block)
  end

  class Core

    # PageStore storing all Page objects encountered during the crawl
    attr_reader :pages
    # Hash of options for the crawl
    attr_reader :opts

    attr_reader :page_queue, :link_queue

    DEFAULT_OPTS = {
      # run 4 Tentacle threads to fetch pages
      :threads => 4,
      # disable verbose output
      :verbose => false,
      # don't throw away the page response body after scanning it for links
      :discard_page_bodies => false,
      # identify self as Anemone/VERSION
      :user_agent => "Anemone/#{Anemone::VERSION}",
      # no delay between requests
      :delay => 0,
      # don't obey the robots exclusion protocol
      :obey_robots_txt => false,
      # by default, don't limit the depth of the crawl
      :depth_limit => false,
      # number of times HTTP redirects will be followed
      :redirect_limit => 5,
      # storage engine defaults to Hash in +process_options+ if none specified
      :storage => nil,
      # Hash of cookie name => value to send with HTTP requests
      :cookies => nil,
      # accept cookies from the server and send them back?
      :accept_cookies => false,
      # skip any link with a query string? e.g. http://foo.com/?u=user
      :skip_query_strings => false,
      # proxy server hostname 
      :proxy_host => nil,
      # proxy server port number
      :proxy_port => false,
      # HTTP read timeout in seconds
      :read_timeout => nil,
      # How long to wait before deeming a distributed crawl finished
      :finish_timeout => 10
    }

    # Create setter methods for all options to be called from the crawl block
    DEFAULT_OPTS.keys.each do |key|
      define_method "#{key}=" do |value|
        @opts[key.to_sym] = value
      end
    end

    #
    # Initialize the crawl with starting *urls* (single URL or Array of URLs)
    # and optional *block*
    #
    def initialize(urls, opts = {})
      @urls = [urls].flatten.map{ |url| url.is_a?(URI) ? url : URI(url) }
      @urls.each{ |url| url.path = '/' if url.path.empty? }

      @tentacles = []
      @on_every_page_blocks = []
      @on_pages_like_blocks = Hash.new { |hash,key| hash[key] = [] }
      @skip_link_patterns = []
      @after_crawl_blocks = []
      @opts = opts

      yield self if block_given?
    end

    #
    # Convenience method to start a new crawl
    #
    def self.crawl(urls, opts = {})
      self.new(urls, opts) do |core|
        yield core if block_given?
        core.run
      end
    end

    #
    # Add a block to be executed on the PageStore after the crawl
    # is finished
    #
    def after_crawl(&block)
      @after_crawl_blocks << block
      self
    end

    #
    # Add one ore more Regex patterns for URLs which should not be
    # followed
    #
    def skip_links_like(*patterns)
      @skip_link_patterns.concat [patterns].flatten.compact
      self
    end

    #
    # Add a block to be executed on every Page as they are encountered
    # during the crawl
    #
    def on_every_page(&block)
      @on_every_page_blocks << block
      self
    end

    #
    # Add a block to be executed on Page objects with a URL matching
    # one or more patterns
    #
    def on_pages_like(*patterns, &block)
      if patterns
        patterns.each do |pattern|
          @on_pages_like_blocks[pattern] << block
        end
      end
      self
    end

    #
    # Specify a block which will select which links to follow on each page.
    # The block should return an Array of URI objects.
    #
    def focus_crawl(&block)
      @focus_crawl_block = block
      self
    end

    #
    # Perform the crawl
    #
    def run
      process_options

      @urls.delete_if { |url| !visit_link?(url) }

      @opts[:threads].times do
        @tentacles << Tentacle.new(new_queue(:link), new_queue(:page), @opts)
      end

      if @opts[:init]
        @urls.each{ |url| link_queue.enq(url) }
        return @opts[:tag]
      end

      loop do
        page = page_queue.deq
        if page.nil?
          if finished?
            break
          else
            sleep(1)
            # puts "nothing in page queue, sleeping"
            next
          end
        end

        @pages.touch_key page.url
        puts "#{page.url} Queue: #{link_queue.size}" if @opts[:verbose]
        do_page_blocks page
        page.discard_doc! if @opts[:discard_page_bodies]

        links = links_to_follow page
        links.each do |link|
          link_queue << [link, page.url.dup, page.depth + 1]
        end
        @pages.touch_keys links

        @pages[page.url] = page

        # if we are done with the crawl, tell the threads to end
        # if link_queue.empty? and page_queue.empty?
        #   until link_queue.num_waiting == @tentacles.size
        #     Thread.pass
        #   end
        #   if page_queue.empty?
        #     @tentacles.size.times { link_queue << :END }
        #     break
        #   end
        # end
      end

      @tentacles.each { |tentacle| tentacle.die }
      do_after_crawl_blocks
      self
    end

    def queue(name, options = {})
      @opts[:queue] = [name, options]
    end

    private

    def process_options
      @opts = DEFAULT_OPTS.merge @opts
      @opts[:threads] = 1 if @opts[:delay] > 0
      @opts[:tag] ||= Digest::MD5.hexdigest(rand.to_s)[0,5]
      storage = Anemone::Storage::Base.new(@opts[:storage] || Anemone::Storage.Hash)
      storage.clear if @opts[:init]
      @pages = PageStore.new(storage)
      @robots = Robots.new(@opts[:user_agent]) if @opts[:obey_robots_txt]

      init_queue
      freeze_options
    end

    def init_queue
      @link_queue = new_queue(:link)
      @page_queue = new_queue(:page)

      if @opts[:init]
        @link_queue.clear
        @page_queue.clear
      end
    end

    def new_queue(which = nil)
      driver, options = @opts[:queue]
      raise "queue '%s' not supported at this time" % driver unless driver == :rabbit_mq
      Queue::RabbitMQ.new("#{which}_queue-#{@opts[:tag]}", options)
    end

    #
    # Freeze the opts Hash so that no options can be modified
    # once the crawl begins
    #
    def freeze_options
      @opts.freeze
      @opts.each_key { |key| @opts[key].freeze }
      @opts[:cookies].each_key { |key| @opts[:cookies][key].freeze } rescue nil
    end

    def finished?
      @finished_timer ||= Time.now
      if @link_queue.empty? and @page_queue.empty?
        if Time.now - @finished_timer > @opts[:finish_timeout]
          true
        else
          false
        end
      else
        @finished_timer = nil
        false
      end
    end

    #
    # Execute the after_crawl blocks
    #
    def do_after_crawl_blocks
      @after_crawl_blocks.each { |block| block.call(@pages) }
    end

    #
    # Execute the on_every_page blocks for *page*
    #
    def do_page_blocks(page)
      @on_every_page_blocks.each do |block|
        block.call(page)
      end

      @on_pages_like_blocks.each do |pattern, blocks|
        blocks.each { |block| block.call(page) } if page.url.to_s =~ pattern
      end
    end

    #
    # Return an Array of links to follow from the given page.
    # Based on whether or not the link has already been crawled,
    # and the block given to focus_crawl()
    #
    def links_to_follow(page)
      links = @focus_crawl_block ? @focus_crawl_block.call(page) : page.links
      links.select { |link| visit_link?(link, page) }.map { |link| link.dup }
    end

    #
    # Returns +true+ if *link* has not been visited already,
    # and is not excluded by a skip_link pattern...
    # and is not excluded by robots.txt...
    # and is not deeper than the depth limit
    # Returns +false+ otherwise.
    #
    def visit_link?(link, from_page = nil)
      !@pages.has_page?(link) &&
      !skip_link?(link) &&
      !skip_query_string?(link) &&
      allowed(link) &&
      !too_deep?(from_page)
    end

    #
    # Returns +true+ if we are obeying robots.txt and the link
    # is granted access in it. Always returns +true+ when we are
    # not obeying robots.txt.
    #
    def allowed(link)
      @opts[:obey_robots_txt] ? @robots.allowed?(link) : true
    rescue
      false
    end

    #
    # Returns +true+ if we are over the page depth limit.
    # This only works when coming from a page and with the +depth_limit+ option set.
    # When neither is the case, will always return +false+.
    def too_deep?(from_page)
      if from_page && @opts[:depth_limit]
        from_page.depth >= @opts[:depth_limit]
      else
        false
      end
    end
    
    #
    # Returns +true+ if *link* should not be visited because
    # it has a query string and +skip_query_strings+ is true.
    #
    def skip_query_string?(link)
      @opts[:skip_query_strings] && link.query
    end

    #
    # Returns +true+ if *link* should not be visited because
    # its URL matches a skip_link pattern.
    #
    def skip_link?(link)
      @skip_link_patterns.any? { |pattern| link.path =~ pattern }
    end

  end
end
