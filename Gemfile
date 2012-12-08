source :rubygems
gemspec

# Testing
gem 'rake'
gem 'rspec'
gem 'parallel_tests'

# Serializer
gem 'tnetstring'
gem 'bencode'
gem 'bson'
gem 'multi_json'

# Backends
gem 'dm-core'
gem 'dm-migrations'
gem 'dm-sqlite-adapter'
gem 'fog'
gem 'activerecord', '>= 3.2.9'
gem 'redis'
gem 'mongo'
gem 'couchrest'
gem 'sequel'
gem 'dalli'
gem 'riak-client'
gem 'hashery'

if defined?(JRUBY_VERSION)
  gem 'msgpack-jruby'
  gem 'jdbc-sqlite3'
  gem 'activerecord-jdbc-adapter'
  gem 'activerecord-jdbcsqlite3-adapter'
  gem 'jruby-memcached'
  gem 'ffi' # gdbm for jruby needs ffi
  gem 'gdbm'
else
  gem 'lzoruby'
  gem 'snappy'
  gem 'bert'
  gem 'msgpack'
  gem 'tokyocabinet'
  gem 'memcached'
  gem 'sqlite3'
  gem 'ox'
  gem 'bson_ext'
end

#gem 'cassandra'
#gem 'localmemcache'
