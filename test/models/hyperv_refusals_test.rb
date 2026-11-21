# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# Model-level refusals: the seven sites, the URL VM id, the edit path, and the
# promise that no fog call ever carries the user's string. These need a booted
# Foreman (compute resources are Active Record), so the file looks for the app
# around the plugin — the Foreman tree's rake test:plugins task, or a
# development install — and says so out loud where none exists, rather than
# pretending the tests ran.
ENV['RAILS_ENV'] = 'test'
FOREMAN_BOOT = [
  File.expand_path('../../config/environment.rb', __dir__),
  File.expand_path('../../../config/environment.rb', __dir__),
  File.expand_path('../../../../config/environment.rb', __dir__)
].find { |path| File.exist?(path) }
require FOREMAN_BOOT if FOREMAN_BOOT && !(defined?(Rails) && Rails.application)

if FOREMAN_BOOT || (defined?(Rails) && Rails.application)
  # The device constructors below build the real fog model classes. fog only
  # requires them when a real compute driver is instantiated — which these
  # refusal tests deliberately never do — so load exactly these models.
  require 'fog/hyperv'
  require 'fog/hyperv/compute/models/network_adapter'
  require 'fog/hyperv/compute/models/vhd'
  require 'fog/hyperv/compute/models/hard_drive'
  require 'fog/hyperv/compute/models/dvd_drive'
  require 'fog/hyperv/compute/models/server'
end

# ActiveSupport::TestCase (not bare Minitest) so the assert_not_* family the
# Foreman style demands actually resolves; mocha's API lands on subclasses
# the same way it did on the plain one.
class HypervRefusalsTest < ActiveSupport::TestCase
  VALID_GUID = '94f8b7b0-2a1d-4a1d-9f2e-6c0f1d2e3a4b'
  OTHER_GUID = '11b62f52-3c60-4b8e-a5d1-8f2b7c9d0e41'

  # Records every fog call and the arguments that came with it, and answers
  # every chained method with itself: a legitimate string appearing anywhere in
  # the recording means the promise was broken.
  class FogSpy
    attr_reader :calls

    def initialize(calls = [])
      @calls = calls
    end

    def method_missing(name, *args)
      @calls << [name, args]
      FogSpy.new(@calls)
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end

    def strings
      @calls.flat_map { |(_name, args)| scan(args) }
    end

    private

    def scan(value)
      case value
      when Hash then value.flat_map { |k, v| [k.to_s] + scan(v) }
      when Array then value.flat_map { |v| scan(v) }
      else [value.to_s]
      end
    end
  end

  def setup
    unless FOREMAN_BOOT || (defined?(Rails) && Rails.application)
      skip 'Needs a booted Foreman (rake test:plugins): these cover model-level refusals.'
    end
    begin
      require 'mocha/minitest'
    rescue LoadError
      skip 'mocha is not available outside the Foreman bundle.'
    end

    @fog = FogSpy.new
    @cr = ForemanHyperv::Hyperv.new(
      name: 'lab-cr', url: 'http://hv-node1.lab.maughmer.net:5985/wsman', user: 'u', password: 'p'
    )
    @cr.stubs(:client).returns(@fog)
    @cr.stubs(:hypervisor).returns(stub('hypervisor', name: 'hv-node1.lab.maughmer.net'))
    @cr.stubs(:endpoint_cluster).returns(nil)
    @cr.stubs(:clusters).returns([])
  end

  # --- the URL VM id, a view-permission surface -------------------------------

  def test_find_vm_by_uuid_refuses_before_super
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.find_vm_by_uuid("x';whoami;'") }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.find_vm_by_uuid('some-vm-name') }
    assert_empty @fog.calls
  end

  def test_find_vm_by_uuid_refuses_a_guid_with_a_trailing_payload
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.find_vm_by_uuid("#{VALID_GUID}\n';whoami;'") }
    assert_empty @fog.calls
  end

  def test_vm_from_cluster_owner_raises_instead_of_answering_nil
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.send(:vm_from_cluster_owner, "x';whoami;'") }
    assert_empty @fog.calls
  end

  # --- the refused operations --------------------------------------------------

  def test_destroy_refuses_a_hostile_id_rather_than_reporting_success
    # The old flow turned NotFound into a successful delete; a refusal must
    # raise, or core drops the host record and the machine goes on running.
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.destroy_vm("x';whoami;'") }
    assert_empty @fog.calls
  end

  def test_destroy_is_refused_everywhere
    error = assert_raises(ForemanHyperv::OperationRefused) { @cr.destroy_vm(VALID_GUID) }
    assert_includes error.message, 'refused in code until FOG-10, PLG-15b and PLG-21b have merged'
    assert_empty @fog.calls
  end

  # PLG-15b opened creates for stand-alone machines only. A fog that answers
  # the membership query with anything but a row is unreadable, and
  # unreadable is refused before a single marker is asked, before any fog
  # command goes out, and with none of the user's strings on the wire.
  def test_create_is_refused_when_the_endpoint_does_not_read_as_standalone
    error = assert_raises(ForemanHyperv::OperationRefused) { @cr.create_vm(name: 'lab-vm01') }
    assert_includes error.message, 'did not read as a stand-alone Hyper-V host'
    assert_not_includes @fog.strings, 'lab-vm01'
    assert_empty @fog.calls.select { |(name, _args)| name == :run_cmd },
                 'the markers are only asked when the classifier already answered not-clustered'
    assert_empty @fog.calls.select { |(name, _args)| %i[servers run_cmdlist].include?(name) },
                 'a refused create sends nothing: no servers collection, no fog command'
  end

  # The cluster path stayed locked exactly where PLG-15 left it: refused as
  # the very first act, before the membership read, quoting the canonical
  # enablement sentence.
  def test_cluster_create_is_refused_before_anything_is_asked
    error = assert_raises(ForemanHyperv::OperationRefused) do
      @cr.create_vm(name: 'lab-vm01', cluster_name: 'hv-cluster')
    end
    assert_includes error.message, 'refused in code until FOG-10, PLG-15b and PLG-21b have merged'
    assert_empty @fog.calls
  end

  def test_create_reports_the_string_before_the_refusal_when_both_apply
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.create_vm(name: "vm';whoami;'") }
    assert_empty @fog.calls
  end

  def test_disk_removal_is_refused_on_the_edit_path
    attrs = { volumes_attributes: { '0' => { id: OTHER_GUID, _delete: '1' } } }
    error = assert_raises(ForemanHyperv::OperationRefused) { @cr.save_vm(VALID_GUID, attrs) }
    assert_includes error.message, 'Removing disks from a virtual machine is refused'
    assert_empty @fog.calls
  end

  # --- the edit path and the device hashes --------------------------------------

  def test_edit_refuses_a_forged_interface_placement_and_a_forged_volume_id
    assert_raises(ForemanHyperv::UnsafeIdentifier) do
      @cr.save_vm(VALID_GUID, interfaces_attributes: { '0' => { computer_name: 'x$(whoami)' } })
    end
    assert_raises(ForemanHyperv::UnsafeIdentifier) do
      @cr.save_vm(VALID_GUID, volumes_attributes: { '0' => { id: "a'b" } })
    end
    assert_empty @fog.calls
  end

  def test_new_device_hashes_are_validated
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.new_interface(name: "a'b") }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.new_volume(basename: 'x`whoami`', size: 1024) }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.new_cdrom(path: "x';whoami;'") }
    assert_empty @fog.calls

    # Legitimate hashes are not collateral damage. The disk one runs through
    # the real fog model classes (loaded at the top of this file), so the vhd
    # its constructor demands is a real Vhd, handed out by a stubbed collection.
    vhd = Fog::Hyperv::Compute::Vhd.new(basename: 'Disk 1', size: 1024)
    @fog.stubs(:vhds).returns(stub('vhds', new: vhd))
    @cr.new_interface(name: 'Network Adapter', switch_name: 'Default Switch')
    @cr.new_volume(basename: 'Disk 1', size: 1024)
    @cr.new_cdrom(path: 'C:\\images\\app.iso')
  end

  # --- placement membership ------------------------------------------------------

  def test_cluster_name_must_be_a_member_never_asked_of_the_host
    assert_raises(ForemanHyperv::UnsafeIdentifier) { @cr.new_vm(cluster_name: "x';whoami;'") }
    assert_raises(ForemanHyperv::OperationRefused) { @cr.new_vm(cluster_name: 'HVCLUSTER') } # listing read empty
    assert_empty @fog.calls
  end

  def test_computer_name_must_be_a_name_the_host_reported
    assert_raises(ForemanHyperv::OperationRefused) { @cr.new_vm(computer_name: 'evil.example.com') }
    assert_empty @fog.calls
  end

  def test_a_membership_read_that_will_not_answer_refuses
    # Not a PSError instance: fog's PSError takes a parsed command output, and
    # what matters to the placement gate is only that a membership read failed.
    @cr.stubs(:hypervisor).raises(Fog::Errors::Error, 'membership read did not answer')
    assert_raises(ForemanHyperv::OperationRefused) { @cr.new_vm(computer_name: 'hv-node1.lab.maughmer.net') }
    assert_empty @fog.calls
  end

  def test_placement_names_are_read_unfiltered_and_matched_case_insensitively
    @cr.stubs(:endpoint_cluster).returns(stub('cluster', nodes: [stub('node', name: 'HV-NODE2')]))

    names = @cr.send(:placement_target_names)
    assert_includes names, 'hv-node2'
    assert_includes names, 'hv-node1.lab.maughmer.net' # endpoint host from the URL and Get-VMHost
    # No fog call carried a user string, because none was involved: the reads
    # are the unfiltered Get-VMHost and Get-ClusterNode paths.
    @fog.strings.each { |s| assert_not_includes s, '$(' }
  end

  # --- the public cluster accessor ------------------------------------------

  def test_public_cluster_lookup_never_asks_the_host_about_the_name
    cluster = stub('cluster', name: 'HVCLUSTER', id: 'cid')
    @cr.stubs(:clusters).returns([cluster])

    assert_equal cluster, @cr.cluster('HVCLUSTER')
    assert_nil @cr.cluster("x';whoami;'")
    assert_nil @cr.cluster('NotARealCluster')
    assert_nil @cr.cluster(nil)
    assert_empty @fog.calls
  end

  # --- fog_extensions cluster_name= (assignment-time sink) -------------------------

  def test_cluster_name_assignment_reads_the_listing_and_not_the_name
    service = FogSpy.new(@fog.calls)
    listing = FogSpy.new(@fog.calls)
    member = stub('cluster', name: 'HVCLUSTER', id: 'cid')

    fog_server = Fog::Hyperv::Compute::Server.new(service: service)
    service.stubs(:clusters).returns(listing)
    listing.stubs(:all).returns([member])

    fog_server.cluster_name = 'hvcluster' # case-insensitive membership
    assert_equal 'HVCLUSTER', fog_server.cluster.name

    assert_raises(ForemanHyperv::OperationRefused) { fog_server.cluster_name = 'NOTACLUSTER' }
    assert_raises(ForemanHyperv::UnsafeIdentifier) { fog_server.cluster_name = "x';whoami;'" }
    # And the name never went to fog as a filter: no call carried it.
    @fog.strings.each { |s| assert_not_includes s, 'whoami' }
    get_calls = @fog.calls.select { |(name, _args)| name == :get }
    assert_empty get_calls
  end
end
