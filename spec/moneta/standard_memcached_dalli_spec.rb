describe 'standard_memcached_dalli', isolate: true, retry: 3 do
  let(:t_res) { 1 }
  let(:min_ttl) { 2 }

  moneta_store :MemcachedDalli, {namespace: "simple_memcached_dalli"}
  moneta_specs STANDARD_SPECS.with_native_expires
end
