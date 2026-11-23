# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# PLG-32: the operator's deliberate opt-out of WinRM certificate verification,
# and the transport refusals' honesty about it. The trust model is row (w)'s,
# verbatim: http composes for any identity; https composes for a hostname a
# certificate can be verified against, which on this platform means an
# explicit hyperv_ca_trust_path (fog's default store does not see the system
# anchors). PLG-5b refused to FORCE verification off on the operator; PLG-32
# hands the choice to the operator instead — hyperv_ssl_verify defaults to
# true and the fog wire is byte-identical until it is switched off. When it
# is off, hostname verification — the exact thing the opt-out removes — can
# no longer be the reason to refuse, so https composes for any identity the
# way http does. The scheme-sanity refusal is NOT relaxed: the opt-out is
# about certificate trust, not about garbage URLs. The refusal texts (still
# fired while verification is on) must name the opt-out next to the reason,
# so a refused operator is told the lever that exists rather than sold a
# dead end.
ENV['RAILS_ENV'] = 'test'
unless defined?(FOREMAN_BOOT)
  FOREMAN_BOOT = [
    File.expand_path('../../config/environment.rb', __dir__),
    File.expand_path('../../../config/environment.rb', __dir__),
    File.expand_path('../../../../config/environment.rb', __dir__)
  ].find { |path| File.exist?(path) }
end
require FOREMAN_BOOT if FOREMAN_BOOT && !(defined?(Rails) && Rails.application)

require 'fog/hyperv' if FOREMAN_BOOT || (defined?(Rails) && Rails.application)

class HypervSslVerifyTest < ActiveSupport::TestCase
  alias assert_not refute

  CR_HOST = 'hv-node1.lab.maughmer.net'
  CR_URL = "http://#{CR_HOST}:5985/wsman".freeze
  CR_URL_TLS = "https://#{CR_HOST}:5986/wsman".freeze
  OWNER_NODE = 'HV-NODE2'
  NODE_IP = '192.168.1.67'
  NODE_FQDN = 'hv-node2.lab.maughmer.net'
  CA_FILE = '/etc/pki/hv-lab/ca.crt'

  def setup
    unless FOREMAN_BOOT || (defined?(Rails) && Rails.application)
      skip 'Needs a booted Foreman (rake test:plugins): these cover model-level transport semantics.'
    end
    begin
      require 'mocha/minitest'
    rescue LoadError
      skip 'mocha is not available outside the Foreman bundle.'
    end
  end

  def build_cr(url: CR_URL, overrides: nil, ca_trust_path: nil, ssl_verify: :unset)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: url, user: 'u', password: 'p')
    cr.hyperv_node_overrides = overrides
    cr.hyperv_ca_trust_path = ca_trust_path if trust_column?
    cr.hyperv_ssl_verify = ssl_verify if ssl_verify != :unset && verify_column?
    cr.stubs(:client).returns(Object.new)
    cr
  end

  def trust_column?
    return @trust_column unless @trust_column.nil?

    @trust_column = ComputeResource.column_names.include?('hyperv_ca_trust_path')
  end

  def verify_column?
    return @verify_column unless @verify_column.nil?

    @verify_column = ComputeResource.column_names.include?('hyperv_ssl_verify')
  end

  # ---- the wire: absent unless the operator opted out ----

  # PLG-32 changes NOTHING for a resource that never opted out: the option is
  # not sent at all and fog's own verified default runs — the pre-PLG-32 wire,
  # byte for byte. (Runs at base too: it is the regression guard, not the
  # feature proof.)
  def test_a_resource_that_never_opted_out_reaches_fog_without_the_option
    cr = build_cr
    cr.unstub(:client)
    Fog::Compute.expects(:new).with { |options| !options.key?(:hyperv_ssl_verify) }.returns(Object.new)
    cr.send(:client)
  end

  def test_the_new_resource_defaults_to_verifying
    skip 'the hyperv_ssl_verify column has not been migrated in this test database' unless verify_column?
    assert_equal true, ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u',
                                                 password: 'p').hyperv_ssl_verify
  end

  def test_opting_out_puts_the_option_false_on_the_resources_own_client
    skip 'the hyperv_ssl_verify column has not been migrated in this test database' unless verify_column?
    cr = build_cr(ssl_verify: false)
    cr.unstub(:client)
    Fog::Compute.expects(:new).with do |options|
      options.key?(:hyperv_ssl_verify) && options[:hyperv_ssl_verify] == false &&
        options[:hyperv_endpoint] == CR_URL
    end.returns(Object.new)
    cr.send(:client)
  end

  # Both composition sites or the opt-out is a lie: the resource's own client
  # runs test_connection and the cluster reads, so an opt-out that reached
  # only the routed clients would fail the very Test Connection it promises.
  def test_opting_out_puts_the_option_false_on_the_per_node_client
    skip 'the hyperv_ssl_verify column has not been migrated in this test database' unless verify_column?
    cr = build_cr(overrides: "hv-node2 = #{NODE_IP}", ssl_verify: false)
    Fog::Compute.expects(:new).with do |options|
      options[:hyperv_ssl_verify] == false && options[:hyperv_endpoint] == "http://#{NODE_IP}:5985/wsman"
    end.returns(Object.new)
    cr.send(:client_for_node, OWNER_NODE)
  end

  # The checkbox posts the STRING 'false'; the column cast is what the model
  # reads, and the composition decision hangs on it being the real false.
  def test_the_string_false_from_a_form_casts_to_the_opt_out
    skip 'the hyperv_ssl_verify column has not been migrated in this test database' unless verify_column?
    cr = build_cr(ssl_verify: 'false')
    assert_equal false, cr.hyperv_ssl_verify, 'the boolean column must cast the form string'
    cr.unstub(:client)
    Fog::Compute.expects(:new).with { |options| options[:hyperv_ssl_verify] == false }.returns(Object.new)
    cr.send(:client)
  end

  # Opted out AND a trust file named: both ride. The opt-out wins the
  # verification decision, but the plugin does not quietly drop the file.
  def test_opting_out_still_hands_fog_the_trust_path_it_named
    skip 'the hyperv_ssl_verify column has not been migrated in this test database' unless verify_column?
    cr = build_cr(ca_trust_path: CA_FILE, ssl_verify: false)
    cr.unstub(:client)
    Fog::Compute.expects(:new).with do |options|
      options[:hyperv_ssl_verify] == false && options[:hyperv_ca_trust_path] == CA_FILE
    end.returns(Object.new)
    cr.send(:client)
  end

  # ---- composition: the opt-out opens exactly what hostname verification
  # was the reason for, and nothing else ----

  def test_opting_out_composes_https_for_an_ipv4_identity
    skip 'the hyperv_ssl_verify column has not been migrated in this test database' unless verify_column?
    cr = build_cr(url: CR_URL_TLS, overrides: "hv-node2 = #{NODE_IP}", ssl_verify: false)
    assert_equal "https://#{NODE_IP}:5986/wsman", cr.send(:node_endpoint, OWNER_NODE)
  end

  def test_opting_out_composes_https_without_a_trust_path
    skip 'the hyperv_ssl_verify column has not been migrated in this test database' unless verify_column?
    cr = build_cr(url: CR_URL_TLS, overrides: "hv-node2 = #{NODE_FQDN}", ssl_verify: false)
    assert_equal "https://#{NODE_FQDN}:5986/wsman", cr.send(:node_endpoint, OWNER_NODE)
  end

  # Verification ON is the PLG-5b rule, untouched: naming the CA file does
  # NOT rescue an IPv4 identity (the refusal is hostname verification, which
  # a CA file cannot answer for).
  def test_verification_on_still_refuses_the_ipv4_identity_even_with_a_trust_path
    skip 'the hyperv_ca_trust_path column has not been migrated in this test database' unless trust_column?
    cr = build_cr(url: CR_URL_TLS, overrides: "hv-node2 = #{NODE_IP}", ca_trust_path: CA_FILE)
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
    assert_includes error.message.downcase, 'hostname'
  end

  # The opt-out is about certificate trust, not URL sanity: an unvalidated
  # scheme stays refused while verification is off.
  def test_opting_out_does_not_bend_the_scheme_sanity_refusal
    skip 'the hyperv_ssl_verify column has not been migrated in this test database' unless verify_column?
    cr = build_cr(url: 'ftp://hv-node1.example.com/wsman', overrides: "hv-node2 = #{NODE_FQDN}",
                  ssl_verify: false)
    assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
  end

  # ---- the refusal texts (fired while verification is ON): the opt-out is
  # named next to the reason, so the text never sells a dead end ----

  def test_the_https_ip_refusal_names_the_opt_out_next_to_the_hostname_reason
    cr = build_cr(url: CR_URL_TLS, overrides: "hv-node2 = #{NODE_IP}")
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
    assert_includes error.message.downcase, 'hostname', 'the PLG-5b reason stays stated'
    assert_includes error.message, 'hyperv_ssl_verify',
                    'the text that once called the opt-out "not this plugin\'s choice" must now ' \
                    'name it as the operator\'s lever'
  end

  def test_the_https_no_trust_refusal_names_the_opt_out_next_to_the_ca_attribute
    skip 'the hyperv_ca_trust_path column has not been migrated in this test database' unless trust_column?
    cr = build_cr(url: CR_URL_TLS, overrides: "hv-node2 = #{NODE_FQDN}")
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
    assert_includes error.message, 'hyperv_ca_trust_path', 'the PLG-5b reason stays stated'
    assert_includes error.message, 'hyperv_ssl_verify',
                    'naming the CA file is not the only lever left, so the text must say so'
  end

  # The scheme refusal enumerates what composes; the opt-out is now part of
  # that enumeration.
  def test_the_scheme_refusal_enumerates_the_opt_out_as_part_of_what_composes
    cr = build_cr(url: 'ftp://hv-node1.example.com/wsman', overrides: "hv-node2 = #{NODE_FQDN}")
    error = assert_raises(ForemanHyperv::OperationRefused) { cr.send(:node_endpoint, OWNER_NODE) }
    assert_includes error.message, 'hyperv_ssl_verify'
  end
end
