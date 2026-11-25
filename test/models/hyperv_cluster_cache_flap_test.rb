# frozen_string_literal: true

require 'test_helper'

# PLG-44 (review F12): one probe flap must not poison the cluster cache.
#
# fog's Real#supports_clusters? rescues every transport error into false, so
# one WinRM flap used to memoize the stand-alone answer for the whole
# instance (cluster_endpoint?), which built the cache object with core's
# 180-minute default while _clusters folded the same flap into [] — and core's
# ComputeResourceCache#cache WRITES whatever the block answers. Measured live
# on this lab with the base gem (evidence plg44-spike1): the simulated flap
# wrote [] under the clusters key with expires_in 180.minutes. Placement,
# storage attribution (delete), and the bootdisk CSV roots all read that
# listing, so one flap refused them for up to three hours.
#
# The fix is PLG-35's own doctrine moved to the two poison doors: a single no
# is re-asked ONCE across the shared flap pause before it becomes an answer;
# the listing gate rides that confirmed answer instead of probing fresh (so
# listing and lifetime can no longer disagree inside one instance); and a
# listing read that raises through its retry answers nil, which #clusters
# turns into a raise through core's cache — core's unconditional write never
# runs, nothing poisoned is stored, and the next request reads the truth.
# (Base's fold [] was truthy in Ruby, so core SERVED it for the whole TTL.)
# What may still cache: a real listing, an honest empty, and the [] of a
# CONFIRMED stand-alone verdict. A gate memo that came from a RAISE keeps
# the established fold but is no verdict (round 39): it answers the
# failed-read nil and caches nothing either.
class HypervClusterCacheFlapTest < ActiveSupport::TestCase
  CR_URL = 'http://hv-node1.lab.example:5985/wsman'

  # A cluster as fog reports it: only the attributes hop matters here.
  ClusterDouble = Struct.new(:name) do
    def attributes
      { name: name }
    end
  end

  # A fog whose cluster probe answers from a scripted list (the last answer
  # repeats). A flap IS this shape from the plugin's seat: fog swallows the
  # transport error into false, so only the SEQUENCE tells a hiccup from a
  # stand-alone host — a flap's second ask says yes, a stand-alone host
  # never does. The clusters listing counts its asks and raises a scripted
  # number of times before answering.
  class FlapFog
    attr_reader :probe_calls, :listing_calls

    def initialize(probe_answers:, clusters: [], raise_times: 0, probe_raise_times: 0)
      @probe_answers = probe_answers
      @clusters = clusters
      @raise_times = raise_times
      @probe_raise_times = probe_raise_times
      @probe_calls = 0
      @listing_calls = 0
      @collection = Listing.new(self)
    end

    def supports_clusters?
      @probe_calls += 1
      raise Timeout::Error, 'fog outside its swallow-everything contract' if @probe_calls <= @probe_raise_times

      @probe_answers[[@probe_calls - 1, @probe_answers.size - 1].min]
    end

    def clusters
      @collection
    end

    def next_listing
      @listing_calls += 1
      raise Timeout::Error, 'simulated WinRM flap' if @listing_calls <= @raise_times

      @clusters
    end

    # The fog collection: #all is the live read, #load the attribute side
    # core's collection takes back to the page — the fake hands the array
    # straight back so tests see exactly what was (or was not) cached.
    class Listing
      def initialize(fog)
        @fog = fog
      end

      def all
        @fog.next_listing
      end

      def load(list)
        list
      end
    end
  end

  # A fog that does not carry the cluster vocabulary at all: it cannot flap,
  # it cannot be re-asked, and it must not be dialed.
  SilentFog = Class.new

  def build_cr(fog)
    cr = ForemanHyperv::Hyperv.new(name: 'lab-cr', url: CR_URL, user: 'u', password: 'p')
    cr.stubs(:client).returns(fog)
    # The re-ask waits out the flap pause; the suite pins the CALLS and
    # never runs the clock (the same seam PLG-35 set).
    cr.stubs(:flap_pause)
    cr
  end

  # Core's cache is only live for a persisted, CACHING-ENABLED resource
  # (ComputeResourceCache#cache_enabled? asks both). These tests ride the
  # REAL ComputeResourceCache and the real Rails cache store under an id no
  # other test uses; keys are deleted before and after so the shared store
  # keeps no residue.
  def build_persisted_cr(fog, id: 987_654)
    cr = build_cr(fog)
    cr.stubs(:persisted?).returns(true)
    cr.stubs(:id).returns(id)
    cr.stubs(:caching_enabled).returns(true)
    cr
  end

  def clusters_key(cr)
    "#{cr.send(:cache).send(:cache_key)}clusters"
  end

  def cleanup_cache(cr)
    Rails.cache.delete(clusters_key(cr))
    Rails.cache.delete("compute_resource_#{cr.id}-cache_scope_key")
  end

  # Rails.cache.write is watched on the store's singleton — the only seat
  # from which the duration an entry is WRITTEN with is observable. The
  # original bound Method is captured and re-bound in ensure: a singleton
  # entry remains, but it points at the store's own original write, so the
  # store answers write exactly as before. The body touches only closure
  # locals (an ivar here would bind to the CACHE STORE, not the test).
  def watch_writes
    writes = []
    original = Rails.cache.method(:write)
    Rails.cache.define_singleton_method(:write) do |key, value, options = nil, &blk|
      opts = options || {}
      writes << [key.to_s, value, opts[:expires_in]]
      original.call(key, value, options, &blk)
    end
    begin
      yield writes
      writes
    ensure
      Rails.cache.define_singleton_method(:write, original)
    end
  end

  def cluster_writes(writes)
    writes.select { |(key, _value, _ttl)| key.include?('clusters') }
  end

  # ---- the gate: a single no is re-asked, a verdict still ends the question

  def test_one_flapped_no_is_re_asked_once_before_it_becomes_the_answer
    fog = FlapFog.new(probe_answers: [false, true])
    cr = build_cr(fog)
    cr.expects(:flap_pause).once

    assert_equal true, cr.send(:cluster_endpoint?),
                 'a no is a could-be-a-flap, not a verdict (PLG-35 doctrine at the gate)'
    assert_equal 2, fog.probe_calls, 'exactly one re-ask across the pause; a yes ends the question'
  end

  def test_two_consistent_nos_are_the_verdict_and_there_is_no_third_ask
    fog = FlapFog.new(probe_answers: [false, false])
    cr = build_cr(fog)

    assert_equal false, cr.send(:cluster_endpoint?)
    assert_equal 2, fog.probe_calls, 'two consistent asks are the verdict — the doctrine must not spin'
  end

  def test_a_yes_pays_the_doctrine_nothing
    fog = FlapFog.new(probe_answers: [true])
    cr = build_cr(fog)
    cr.expects(:flap_pause).never

    assert_equal true, cr.send(:cluster_endpoint?)
    assert_equal 1, fog.probe_calls, 'a yes is accepted at once — no re-ask, no pause'
  end

  def test_a_fog_without_the_vocabulary_is_answered_false_without_a_pause
    cr = build_cr(SilentFog.new)
    cr.expects(:flap_pause).never

    assert_equal false, cr.send(:cluster_endpoint?),
                 'a fog that cannot answer this question cannot flap — no dial, no re-ask'
  end

  def test_the_flapped_gate_that_re_asks_yes_builds_the_cluster_lifetime_and_lists
    fog = FlapFog.new(probe_answers: [false, true], clusters: [ClusterDouble.new('lab-cluster')])
    cr = build_cr(fog)

    listed = cr.clusters

    assert_equal 5.minutes, cr.send(:cache).cache_duration,
                 'the flapped no must not pick core 180.minutes (live spike: [] written at 180)'
    assert_equal ['lab-cluster'], listed.pluck(:name),
                 'the cluster the re-ask confirmed keeps its listing'
  end

  # ---- the listing: failed reads answer empty but never reach the cache

  def test_a_failed_listing_answers_nil_not_the_empty_verdict
    fog = FlapFog.new(probe_answers: [true], clusters: [], raise_times: 5)
    cr = build_cr(fog)
    cr.expects(:flap_pause).once

    assert_nil cr.send(:_clusters),
               'nil is "the read failed" — the answer that keeps it out of the cache; [] is a VERDICT'
    assert_equal 2, fog.listing_calls, 'the listing rides PLG-35 read-retry: one pause, one re-read'
  end

  # Cold miss + transport down: base's fold cached its [] (truthy in Ruby —
  # core's cache then SERVES it for the whole TTL); the branch writes nothing
  # and the next request reads the truth.
  def test_a_failed_listing_answers_empty_writes_nothing_and_the_next_request_recovers
    # raise_times 2: every read of the FIRST call (two attempts across the
    # pause) fails; the transport is back for the request after it.
    fog = FlapFog.new(probe_answers: [true], clusters: [ClusterDouble.new('lab-cluster')],
                      raise_times: 2)
    cr = build_persisted_cr(fog)
    cleanup_cache(cr)

    begin
      listed = nil
      writes = watch_writes { listed = cr.clusters }

      assert_equal [], listed, 'the page gets the same degraded empty it gets today'
      assert_empty cluster_writes(writes),
                   'the failed read writes NOTHING (base wrote its fold [] under the key)'

      recovered = cr.clusters
      assert_equal ['lab-cluster'], recovered.pluck(:name),
                   'the failed read left nothing behind: the next request reads the truth, ' \
                   'where base served its cached [] for the whole TTL'
    ensure
      cleanup_cache(cr)
    end
  end

  def test_a_single_flap_of_the_listing_itself_is_absorbed_by_the_retry
    fog = FlapFog.new(probe_answers: [true], clusters: [ClusterDouble.new('lab-cluster')],
                      raise_times: 1)
    cr = build_persisted_cr(fog)
    cr.expects(:flap_pause).once
    cleanup_cache(cr)

    begin
      listed = nil
      writes = watch_writes { listed = cr.clusters }

      assert_equal 2, fog.listing_calls, 'the first raise is retried once across the pause'
      assert_equal ['lab-cluster'], listed.pluck(:name), 'the retry answers the page the truth'
      cached = cluster_writes(writes)
      assert_equal 1, cached.size, 'the READ that succeeded is the answer that caches'
      assert_equal 5.minutes, cached.first[2], 'at the cluster lifetime the confirmed gate picked'
    ensure
      cleanup_cache(cr)
    end
  end

  # ---- what may still cache: verdicts and honest answers

  def test_a_confirmed_standalone_verdict_still_caches_the_empty
    fog = FlapFog.new(probe_answers: [false, false])
    cr = build_persisted_cr(fog)
    cleanup_cache(cr)

    begin
      listed = nil
      writes = watch_writes { listed = cr.clusters }

      assert_equal [], listed
      cached = cluster_writes(writes)
      assert_equal 1, cached.size,
                   'the F12 fix must not become a no-caching-ever: a CONFIRMED verdict caches'
      assert_equal [], cached.first[1]
      assert_equal 180.minutes, cached.first[2], 'a stand-alone endpoint keeps core 180.minutes'
    ensure
      cleanup_cache(cr)
    end
  end

  def test_an_honest_empty_listing_caches_at_the_cluster_lifetime
    fog = FlapFog.new(probe_answers: [true], clusters: [])
    cr = build_persisted_cr(fog)
    cleanup_cache(cr)

    begin
      writes = watch_writes { cr.clusters }

      cached = cluster_writes(writes)
      assert_equal 1, cached.size, 'an endpoint that truly lists nothing writes its honest empty'
      assert_equal [], cached.first[1]
      assert_equal 5.minutes, cached.first[2],
                   'on a clustered endpoint even the empty lives five minutes, not three hours'
    ensure
      cleanup_cache(cr)
    end
  end

  def test_the_listing_gate_rides_the_confirmed_answer_and_probes_nothing_fresh
    fog = FlapFog.new(probe_answers: [true], clusters: [ClusterDouble.new('lab-cluster')])
    cr = build_persisted_cr(fog)
    cleanup_cache(cr)

    begin
      watch_writes { cr.clusters }

      assert_equal 1, fog.probe_calls,
                   'one confirmed answer serves the lifetime AND the listing gate; base asked ' \
                   'twice on a cold miss, and those two asks could disagree mid-flap'
    ensure
      cleanup_cache(cr)
    end
  end

  # ---- the raise door (round 39, F1): fog outside its own contract ----

  def test_a_gate_memo_from_a_raising_probe_folds_but_caches_nothing
    # supports_clusters? RAISING is fog outside its swallow-everything
    # contract. The gate keeps the established fold (the warn, the false
    # memo, no re-ask — a raise short-circuits the doctrine's second ask),
    # but the fold is a could-not-answer, not a verdict: the listing
    # answers the failed-read nil, so the store gets neither the fold's []
    # nor a stand-alone 180.minutes over it. Base cached [] here for three
    # hours — the same F12 exposure through the raise door.
    fog = FlapFog.new(probe_answers: [], probe_raise_times: 10)
    cr = build_persisted_cr(fog)
    cr.expects(:flap_pause).never
    cleanup_cache(cr)

    begin
      listed = nil
      writes = watch_writes { listed = cr.clusters }

      assert_equal [], listed, 'the page still gets the degraded empty it gets today'
      assert_equal false, cr.send(:cluster_endpoint?), 'the established fold: the false memo stands'
      assert_equal 1, fog.probe_calls, 'the raise short-circuits before the doctrine asks again'
      assert_empty cluster_writes(writes),
                   'a raise-fold caches NOTHING (base wrote its [] at 180.minutes here)'
    ensure
      cleanup_cache(cr)
    end
  end
end
