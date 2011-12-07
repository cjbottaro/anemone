require 'anemone/http'

module Anemone
  class Tentacle

    #
    # Create a new Tentacle
    #
    def initialize(link_queue, page_queue, opts = {})
      @link_queue = link_queue
      @page_queue = page_queue
      @http = Anemone::HTTP.new(opts)
      @opts = opts
      @idle = false
      @lock = Mutex.new
      @thread = Thread.new{ run }
    end

    def idle?
      @lock.synchronize{ @idle }
    end

    def die
      @die = true
      @thread.join
    end

    #
    # Gets links from @link_queue, and returns the fetched
    # Page objects into @page_queue
    #
    def run
      link, referer, depth = nil

      loop do

        @lock.synchronize do
          link, referer, depth = @link_queue.deq
          if link.nil?
            @idle = true
          else
            @idle = false
          end
        end

        if @die
          break
        elsif link.nil?
          # puts "nothing in link queue, sleeping"
          sleep(1)
          next
        end

        @http.fetch_pages(link, referer, depth).each { |page| @page_queue << page }

        delay
      end
    end

    private

    def delay
      sleep @opts[:delay] if @opts[:delay] > 0
    end

  end
end
