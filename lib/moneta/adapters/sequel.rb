require 'sequel'

module Moneta
  module Adapters
    # Sequel backend
    # @api public
    class Sequel
      include Defaults

      # Sequel::UniqueConstraintViolation is defined since sequel 3.44.0
      # older versions raise a Sequel::DatabaseError.
      UniqueConstraintViolation = defined?(::Sequel::UniqueConstraintViolation) ? ::Sequel::UniqueConstraintViolation : ::Sequel::DatabaseError

      supports :create, :increment
      attr_reader :backend

      # @param [Hash] options
      # @option options [String] :db Sequel database
      # @option options [String/Symbol] :table (:moneta) Table name
      # @option options [Array] :extensions ([]) List of Sequel extensions
      # @option options [Integer] :connection_validation_timeout (nil) Sequel connection_validation_timeout
      # @option options All other options passed to `Sequel#connect`
      # @option options [Sequel connection] :backend Use existing backend instance
      def initialize(options = {}, backend)
        @backend = backend
        table = (options.delete(:table) || :moneta).to_sym

        @backend.create_table?(table) do
          String :k, null: false, primary_key: true
          File :v
        end
        @table = @backend[table]
      end

      # (see Proxy#key?)
      def key?(key, options = {})
        !@table.where(k: key).empty?
      end

      # (see Proxy#load)
      def load(key, options = {})
        @table.where(k: key).get(:v)
      end

      # (see Proxy#store)
      def store(key, value, options = {})
        blob_value = blob(value)
        unless @table.where(k: key).update(v: blob(value)) == 1
          @table.insert(k: key, v: blob(value))
        end
        value
      rescue ::Sequel::DatabaseError
        tries ||= 0
        (tries += 1) < 10 ? retry : raise
      end

      # (see Proxy#store)
      def create(key, value, options = {})
        @table.insert(k: key, v: blob(value))
        true
      rescue UniqueConstraintViolation
        false
      end

      # (see Proxy#increment)
      def increment(key, amount = 1, options = {})
        begin
          @table.insert(k: key, v: amount)
          amount
        rescue UniqueConstraintViolation
          @backend.transaction do
            if existing = load(key)
              Integer(existing)
            end
            raise "no update" unless @table.where(k: key).update(v: ::Sequel.+(:v, amount)) == 1
            load(key).to_i
          end
        end
      rescue
        # Concurrent modification might throw a bunch of different errors
        tries ||= 0
        (tries += 1) < 10 ? retry : raise
      end

      # (see Proxy#delete)
      def delete(key, options = {})
        value = load(key, options)
        @table.filter(k: key).delete
        value
      end

      # (see Proxy#clear)
      def clear(options = {})
        @table.delete
        self
      end

      # (see Proxy#close)
      def close
        @backend.disconnect
        nil
      end

      private

      # See https://github.com/jeremyevans/sequel/issues/715
      def blob(s)
        s.empty? ? '' : ::Sequel.blob(s)
      end

      def self.new(*args)
        return super if args.length == 2
        options = args.first || {}

        table = (options.delete(:table) || :moneta).to_sym
        backend = options[:backend] ||
          begin
            raise ArgumentError, 'Option :db is required' unless db = options.delete(:db)
            ::Sequel.connect(db, options).tap do |backend|
              extensions = options.delete(:extensions) || []
              raise ArgumentError, 'Option :extensions must be an Array' unless extensions.is_a?(Array)
              extensions.map(&:to_sym).each(&backend.method(:extension))

              if connection_validation_timeout = options.delete(:connection_validation_timeout)
                backend.pool.connection_validation_timeout = connection_validation_timeout
              end
            end
          end

        case backend.database_type
        when :mysql
          MySQL.new(options, backend)
        when :postgres
          Postgres.new(options, backend)
        when :sqlite
          SQLite.new(options, backend)
        else
          super(options, backend)
        end
      end

      class MySQL < Sequel
        def store(key, value, options = {})
          blob_value = blob(value)
          @table.on_duplicate_key_update(v: blob_value).insert(k: key, v: blob_value)
          value
        end

        def increment(key, amount = 1, options = {})
          @backend.transaction do
            if existing = load(key)
              Integer(existing)
            end
            @table.on_duplicate_key_update(v: ::Sequel.+(:v, amount)).insert(k: key, v: amount)
            load(key).to_i
          end
        end
      end

      class Postgres < Sequel
        def store(key, value, options = {})
          blob_value = blob(value)
          @table.insert_conflict(target: :k, update: {v: blob_value}).insert(k: key, v: blob_value)
          value
        end

        def increment(key, amount = 1, options = {})
          @table.
            returning(:v).
            insert_conflict(target: :k, update: {v: ::Sequel.+(:v.identifier, amount)}).
            insert(k: key, v: amount).
            single_value
        end

        def delete(key, options = {})
          @table.returning(:v).where(k: key).delete.single_value
        end
      end

      class SQLite < Sequel
        def store(key, value, options = {})
          @table.insert_conflict(:replace).insert(k: key, v: blob(value))
          value
        end
      end
    end
  end
end
