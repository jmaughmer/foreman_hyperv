# frozen_string_literal: true

require 'test_helper'
require 'active_support/test_case'

# PLG-26: the switch the machine form names is a per-node GUID, and a machine
# placed on another node dials it on the wrong host. The form's switch value
# is the id from the compute resource's own network list — a list read from
# the endpoint — and a virtual switch is per-node: the same name on two nodes
# is two switches with two GUIDs (measured twice, §28 and §33.3's E12b:
# Get-VMSwitch -Id with a foreign node's GUID RAISES "No Ethernet switch
# could be found matching the specified criteria" rather than answering
# empty). So a create onto a second cluster node died in fog's NIC switch
# save (create_interfaces sets the endpoint's switch_id on the VM's NIC, the
# save sees a switch change, and the resolve dials Get-VMSwitch -Id on the
# TARGET node), which is exactly the first clustered machine driven through
# the form (2026-11-22, production.log 19:27:53).
#
# The name is the identifier the nodes share: the network list offers only
# switches whose names every node answers (§28's shared-name listing), so
# the plugin translates the endpoint's GUID back to that name and hands fog
# the name — Get-VMSwitch -Name on the target answers for the node's own
# switch of that name. A GUID the endpoint's list does not carry is left
# exactly as it arrived: that switch is missing even from the endpoint, and
# the loud error it earns is the honest answer, not a silent name miss.
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

class HypervSwitchTranslationTest < ActiveSupport::TestCase
  alias assert_not refute

  CR_URL = 'http://hv-node1.lab.maughmer.net:5985/wsman'
  ENDPOINT_SWITCH_GUID = '908ed04b-1960-48b2-9cab-037e9cebf603'
  FOREIGN_SWITCH_GUID = '05a9ea44-0000-4000-8000-000000000000'

  FakeSwitch = Struct.new(:name, :id)

  # Records exactly which writer the interface hash reached: the bug is the
  # switch_id GUID surviving into the NIC, so the assertion has to be about
  # what the NIC was assigned, not about what fog eventually sent.
  class FakeNic
    attr_accessor :switch_id, :switch_name, :vlan_operation_mode, :mac, :identity
    attr_reader :saved

    def initialize
      @saved = false
    end

    def save
      @saved = true
    end
  end

  def build_cr
    cr = ForemanHyperv::Hyperv.new(
      name: 'lab-hyperv',
      url: CR_URL,
      user: 'hvforeman@lab.maughmer.net',
      password: 'password'
    )
    cr.stubs(:client)
    cr.stubs(:switches).returns([FakeSwitch.new('External', ENDPOINT_SWITCH_GUID)])
    cr
  end

  def build_vm(nic)
    nics = mock('network adapters')
    nics.stubs(:first).returns(nic)
    nics.stubs(:new).returns(nic)
    nics.stubs(:all).returns([])
    vm = mock('vm')
    vm.stubs(:network_adapters).returns(nics)
    vm
  end

  test 'a create connects by the switch name the nodes share, not by the endpoint GUID' do
    cr = build_cr
    nic = FakeNic.new
    vm = build_vm(nic)
    attrs = {
      interfaces_attributes: {
        '0' => { switch_id: ENDPOINT_SWITCH_GUID, vlan_operation_mode: 'Untagged' }
      }
    }

    cr.send(:create_interfaces, vm, attrs)

    assert_equal 'External', nic.switch_name
    assert_nil nic.switch_id
    assert nic.saved
  end

  test 'a GUID the endpoint never reported is passed through untouched' do
    cr = build_cr
    nic = FakeNic.new
    vm = build_vm(nic)
    attrs = {
      interfaces_attributes: {
        '0' => { switch_id: FOREIGN_SWITCH_GUID, vlan_operation_mode: 'Untagged' }
      }
    }

    cr.send(:create_interfaces, vm, attrs)

    assert_equal FOREIGN_SWITCH_GUID, nic.switch_id
    assert_nil nic.switch_name
  end

  test 'an edit resolves the endpoint GUID to the shared name the same way' do
    cr = build_cr
    nic = FakeNic.new
    vm = build_vm(nic)
    attrs = {
      interfaces_attributes: {
        '0' => { compute_attributes: { switch_id: ENDPOINT_SWITCH_GUID, vlan_operation_mode: 'Untagged' } }
      }
    }

    cr.send(:update_interfaces, vm, attrs)

    assert_equal 'External', nic.switch_name
    assert_nil nic.switch_id
    assert nic.saved
  end
end
