module Anemone
  module Queue

    autoload :AbstractBase, "anemone/queue/abstract_base"
    autoload :RabbitMQ,     "anemone/queue/rabbit_mq"
    
    def self.RabbitMQ(*args)
      RabbitMQ.new(*args)
    end

  end
end
