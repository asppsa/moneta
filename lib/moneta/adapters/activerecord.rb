require 'active_record'
require 'uri'

module Moneta
  module Adapters
    # ActiveRecord as key/value stores
    # @api public
    class ActiveRecord
      include Defaults

      supports :create, :increment

      attr_reader :connection_pool, :table, :key_column, :value_column
      delegate :with_connection, to: :connection_pool

      @connection_lock = ::Mutex.new
      class << self
        attr_reader :connection_lock
        delegate :configurations, :configurations=, :connection_handler, to: ::ActiveRecord::Base

        def retrieve_connection_pool(spec_name)
          connection_handler.retrieve_connection_pool(spec_name.to_s)
        end

        def establish_connection(spec_name)
          connection_lock.synchronize do
            if connection_pool = retrieve_connection_pool(spec_name)
              connection_pool
            else
              connection_handler.establish_connection(spec_name.to_sym)
            end
          end
        end

        def retrieve_or_establish_connection_pool(spec_name)
          retrieve_connection_pool(spec_name) || establish_connection(spec_name)
        end
      end

      # @param [Hash] options
      # @option options [Object]               :backend A class object inheriting from ActiveRecord::Base to use as a table
      # @option options [String]               :table ('moneta') Table name
      # @option options [Hash/String/Symbol]   :connection ActiveRecord connection configuration (`Hash` or `String`), or symbol giving the name of a Rails connection (e.g. :production)
      # @option options [Proc]                 :create_table Proc called with a connection if table needs to be created
      # @option options [Symbol]               :key_column The name of the column to use for keys
      # @option options [Symbol]               :value_column The name of the column to use for values
      def initialize(options = {})
        @key_column = options.delete(:key_column) || :k
        @value_column = options.delete(:value_column) || :v

        if backend = options.delete(:backend)
          @connection_pool = backend.connection_pool
          @table = ::Arel::Table.new(backend.table_name.to_sym)
        else
          # Feed the connection info into ActiveRecord and get back a name to use for getting the
          # connection pool
          connection = options.delete(:connection)
          spec =
            case connection
            when Symbol
              connection
            when Hash, String
              # Normalize the connection specification to a hash
              resolver = ::ActiveRecord::ConnectionAdapters::ConnectionSpecification::Resolver.new \
                'dummy' => connection

              # Turn the config into a standardised hash, sans a couple of bits
              hash = resolver.resolve(:dummy)
              hash.delete('name')
              hash.delete(:password) # For security

              # Make a name unique to this config
              name = 'moneta?' + URI.encode_www_form(hash.to_a.sort)

              # Add into configurations unless its already there (initially done without locking for
              # speed)
              unless self.class.configurations.key? name
                self.class.connection_lock.synchronize do
                  self.class.configurations[name] = connection \
                    unless self.class.configurations.key? name
                end
              end

              name.to_sym
            else
              Rails.env.to_sym if defined? Rails
            end

          # If no connection spec is given, fallback to default connection pool
          @connection_pool =
            if spec
              self.class.retrieve_or_establish_connection_pool(spec)
            else
              ::ActiveRecord::Base.connection_pool
            end

          table_name = (options.delete(:table) || :moneta).to_sym
          create_table_if_not_exists(table_name, &options.delete(:create_table))

          @table = ::Arel::Table.new(table_name)
        end
      end

      # (see Proxy#key?)
      def key?(key, options = {})
        with_connection do |conn|
          sel = arel_sel_key(key).project(::Arel.sql('1'))
          result = conn.select_all(sel)
          !result.empty?
        end
      end

      # (see Proxy#load)
      def load(key, options = {})
        with_connection do |conn|
          conn_sel_value(conn, key)
        end
      end

      # (see Proxy#store)
      def store(key, value, options = {})
        with_connection do |conn|
          conn_ins(conn, key, value) unless conn_upd(conn, key, value) == 1
        end
        value
      end

      # (see Proxy#delete)
      def delete(key, options = {})
        with_connection do |conn|
          conn.transaction do
            sel = arel_sel_key(key).project(table[value_column]).lock
            value = conn.select_value(sel)

            del = arel_del.where(table[key_column].eq(key))
            conn.delete(del)

            value
          end
        end
      end

      # (see Proxy#increment)
      def increment(key, amount = 1, options = {})
        with_connection do |conn|
          begin
            conn_ins(conn, key, amount)
            amount
          rescue
            conn.transaction do
              # This will raise if the existing value is not an integer
              conn_sel_int_value(conn, key)
              raise "No row updated" \
                unless conn_upd(conn, key, ::Arel.sql("#{value_column} + #{amount}")) == 1
              conn_sel_int_value(conn, key)
            end
          end
        end
      rescue
        # This handles the "no row updated" issue, above
        tries ||= 0
        if (tries += 1) <= 3; retry else raise end
      end

      # (see Proxy#create)
      def create(key, value, options = {})
        with_connection do |conn|
          conn_ins(conn, key, value)
          true
        end
      rescue
        false
      end

      # (see Proxy#clear)
      def clear(options = {})
        with_connection do |conn|
          conn.delete(arel_del)
        end
        self
      end

      # (see Proxy#close)
      def close
        @table = nil
        @connection_pool = nil
      end

      private

      def create_table_if_not_exists table_name
        with_connection do |conn|
          return if conn.table_exists?(table_name)

          # Prevent multiple connections from attempting to create the table simultaneously.
          self.class.connection_lock.synchronize do
            if block_given?
              yield conn
            else
              conn.create_table(table_name, id: false) do |t|
                # Do not use binary key (Issue #17)
                t.string key_column, null: false
                t.binary value_column
              end
              conn.add_index(table_name, key_column, unique: true)
            end
          end
        end
      end

      def arel_del
        ::Arel::DeleteManager.new.from(table)
      end

      def arel_sel
        ::Arel::SelectManager.new.from(table)
      end

      def arel_upd
        ::Arel::UpdateManager.new.table(table)
      end

      def arel_sel_key(key)
        arel_sel.where(table[key_column].eq(key))
      end

      def conn_ins(conn, key, value)
        ins = ::Arel::InsertManager.new.into(table)
        ins.insert([[table[key_column], key], [table[value_column], value]])
        conn.insert ins
      end

      def conn_upd(conn, key, value)
        conn.update arel_upd.where(table[key_column].eq(key)).set([[table[value_column], value]])
      end

      def conn_sel_value(conn, key)
        conn.select_value arel_sel_key(key).project(table[value_column])
      end

      def conn_sel_int_value(conn, key)
        Integer(conn_sel_value(conn, key))
      end
    end
  end
end
