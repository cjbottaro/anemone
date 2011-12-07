module Anemone
  module Queue
    class AbstractBase

      def initialize(name, options)
        self.class.alias_methods
      end

      def enqueue(item)
        raise_not_implemented
      end

      def dequeue
        raise_not_implemented
      end

      def size
        raise_not_implemented
      end

      def clear
        raise_not_implemented
      end


      def empty?
        size == 0
      end

      def self.alias_methods
        %w[enq push <<].each{ |_alias| alias_method(_alias, :enqueue) }
        %w[deq pop].each{ |_alias| alias_method(_alias, :dequeue) }
        %w[length].each{ |_alias| alias_method(_alias, :size) }
      end

    private
      
      def raise_not_implemented
        method = caller[0].match(/`([^']+)'/)[1]
        raise "#{self.class} needs to implement `#{method}'"
      end

    end
  end
end
