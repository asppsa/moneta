describe 'standard_tokyocabinet_with_expires', isolate: true, unsupported: RUBY_ENGINE == 'jruby' do
  let(:t_res){ 0.1 }
  let(:min_ttl){ t_res }

  moneta_store :TokyoCabinet do
    {file: File.join(tempdir, "simple_tokyocabinet_with_expires"), expires: true}
  end

  moneta_specs STANDARD_SPECS.without_multiprocess.with_expires
end
