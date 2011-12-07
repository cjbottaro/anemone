require "bunny"

module Anemone
  module Queue
    class RabbitMQ < AbstractBase
      def initialize(name, options = {})
        @name = name
        @bunny = Bunny.new(options)
        @bunny.start
        @exchange = @bunny.exchange("")
        @queue = @bunny.queue(@name, :durable => true, :auto_delete => false)
        super
      end

      def enqueue(item)
        @exchange.publish(Marshal.dump(item), :key => @name)
      end

      def dequeue
        message = @queue.pop
        if message[:payload] == :queue_empty
          nil
        else
          Marshal.load(message[:payload])
        end
      end

      def size
        @queue.status[:message_count]
      end

      def clear
        @queue.purge
      end
    end
  end
end
