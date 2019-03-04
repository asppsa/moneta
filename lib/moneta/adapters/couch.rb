require 'faraday'
require 'multi_json'

module Moneta
  module Adapters
    # CouchDB backend
    #
    # You can store hashes directly using this adapter.
    #
    # @example Store hashes
    #     db = Moneta::Adapters::Couch.new
    #     db['key'] = {a: 1, b: 2}
    #
    # @api public
    class Couch
      include Defaults

      attr_reader :backend

      supports :create, :each_key

      # @param [Hash] options
      # @option options [String] :host ('127.0.0.1') Couch host
      # @option options [String] :port (5984) Couch port
      # @option options [String] :db ('moneta') Couch database
      # @option options [String] :value_field ('value') Document field to store value
      # @option options [String] :type_field ('type') Document field to store value type
      # @option options [Faraday connection] :backend Use existing backend instance
      def initialize(options = {})
        @value_field = options[:value_field] || 'value'
        @type_field = options[:type_field] || 'type'
        url = "http://#{options[:host] || '127.0.0.1'}:#{options[:port] || 5984}/#{options[:db] || 'moneta'}"
        @backend = options[:backend] || ::Faraday.new(url: url)
        @rev_cache = Moneta.build do
          use :Lock
          adapter :LRUHash
        end
        create_db
      end

      # (see Proxy#key?)
      def key?(key, options = {})
        response = @backend.head(key)
        update_rev_cache(key, response)
        response.status == 200
      end

      # (see Proxy#load)
      def load(key, options = {})
        response = @backend.get(key)
        update_rev_cache(key, response)
        response.status == 200 ? body_to_value(response.body) : nil
      end

      # (see Proxy#store)
      def store(key, value, options = {})
        body = value_to_body(value, rev(key))
        response = @backend.put(key, body, 'Content-Type' => 'application/json')
        update_rev_cache(key, response)
        raise "HTTP error #{response.status} (PUT /#{key})" unless response.status == 201
        value
      rescue
        tries ||= 0
        (tries += 1) < 10 ? retry : raise
      end

      # (see Proxy#delete)
      def delete(key, options = {})
        clear_rev_cache(key)
        get_response = @backend.get(key)
        if get_response.status == 200
          existing_rev = get_response['etag'][1..-2]
          value = body_to_value(get_response.body)
          delete_response = @backend.delete("#{key}?rev=#{existing_rev}")
          raise "HTTP error #{response.status}" unless delete_response.status == 200
          value
        end
      rescue
        tries ||= 0
        (tries += 1) < 10 ? retry : raise
      end

      # (see Proxy#clear)
      def clear(options = {})
        @backend.delete ''
        create_db
        self
      end

      # (see Proxy#create)
      def create(key, value, options = {})
        body = value_to_body(value, nil)
        response = @backend.put(key, body, 'Content-Type' => 'application/json')
        update_rev_cache(key, response)
        case response.status
        when 201
          true
        when 409
          false
        else
          raise "HTTP error #{response.status}"
        end
      rescue
        tries ||= 0
        (tries += 1) < 10 ? retry : raise
      end

      def each_key
        return enum_for(:each_key) unless block_given?

        skip = 0
        limit = 1000
        total_rows = 1
        while total_rows > skip do
          response = @backend.get("_all_docs?limit=#{limit}&skip=#{skip}")
          case response.status
          when 200
            result = MultiJson.load(response.body)
            total_rows = result['total_rows']
            skip += result['rows'].length
            result['rows'].each do |row|
              key = row['id']
              @rev_cache[key] = row['value']['rev']
              yield key
            end
          else
            raise "HTTP error #{response.status}"
          end
        end
        self
      end

      private

      def body_to_value(body)
        doc = MultiJson.load(body)
        case doc[@type_field]
        when 'Hash'
          doc = doc.dup
          doc.delete('_id')
          doc.delete('_rev')
          doc.delete(@type_field)
          doc
        else
          doc[@value_field]
        end
      end

      def value_to_body(value, rev)
        case value
        when Hash
          doc = value.merge(@type_field => 'Hash')
        when String
          doc = { @value_field => value, @type_field => 'String' }
        when Float, Integer
          doc = { @value_field => value, @type_field => 'Number' }
        else
          raise ArgumentError, "Invalid value type: #{value.class}"
        end
        doc['_rev'] = rev if rev
        MultiJson.dump(doc)
      end

      def create_db
        response = @backend.put '', ''
        raise "HTTP error #{response.status}" unless response.status == 201 || response.status == 412
      end

      def update_rev_cache(key, response)
        case response.status
        when 200, 201
          @rev_cache[key] = response['etag'][1..-2]
        else
          @rev_cache.delete(key)
          nil
        end
      end

      def clear_rev_cache(key)
        @rev_cache.delete(key)
      end

      def rev(key)
        @rev_cache[key] || (
          response = @backend.head(key) and
          update_rev_cache(key, response)).tap do |rev|
        end
      end
    end
  end
end
