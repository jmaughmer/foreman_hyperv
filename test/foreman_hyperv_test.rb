# frozen_string_literal: true

require 'test_helper'

class ForemanHypervTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::ForemanHyperv::VERSION
  end
end
