# frozen_string_literal: true

require 'rake/testtask'

namespace :test do
  desc 'Test ForemanHyperv'
  Rake::TestTask.new :foreman_hyperv do |t|
    test_dir = File.join(__dir__, '../..', 'test')
    t.libs << ['test', test_dir]
    t.pattern = "#{test_dir}/**/*_test.rb"
    t.verbose = true
    t.warning = false
  end
end

namespace :foreman_hyperv do
  task :rubocop => :environment do
    require 'rubocop/rake_task'
    RuboCop::RakeTask.new :rubocop_foreman_hyperv do |task|
      task.patterns = [
        '/app/**/*.rb',
        '/lib/**/*.rb',
        '/test/**/*.rb'
      ].map { |p| "#{ForemanHyperv::Engine.root}#{p}" }
    end
    Rake::Task['rubocop_foreman_hyperv'].invoke
  rescue LoadError
    puts 'Rubocop not loaded'
  end

  # The bootdisk janitor (plan v10 Decision 4, PR-4): age-only sweep of the
  # two transfer roots. Exit 0 for a result — files removed, nothing due, or
  # dormant (roots unset); only a real filesystem fault can make it raise,
  # which is what belongs in the cron log (/var/log/foreman/cron.log).
  desc 'Remove age-exceeded bootdisk transfer files (served ISOs, staging sidecars and .iso.part temps)'
  task bootdisk_janitor: :environment do
    counts = ForemanHyperv::BootdiskTransfer.sweep
    if counts.nil?
      puts 'foreman_hyperv:bootdisk_janitor: hyperv_bootdisk_pull_root/staging_root are not ' \
           'configured — bootdisk is dormant, nothing to sweep.'
    else
      puts format('foreman_hyperv:bootdisk_janitor: removed %<s>d served ISO(s), %<t>d staging file(s).',
                  s: counts[:served], t: counts[:staging])
    end
  end
end

# Decision 4: "runs on the same cadence as the existing scheduled work".
# Resolved by MEASUREMENT (2026-11-25, CI box): foreman 5.0.1 ships
# /etc/cron.d/foreman running foreman-rake cron:hourly at :30 every hour, and
# lib/foreman/cron.rb documents `Foreman::Cron.register(cadence, task)` as the
# plugin hook (core's own registrations sit right under that comment; each
# task's failure is rescued into one logged line, so a fault here cannot take
# the platform's other hourly work down). Hourly + the 24 h age caps a crashed
# ride's ~245 MB at roughly 25 h. NO existence guard: if Foreman::Cron ever
# disappears, a loud NameError at every rake load beats a silent
# registered-by-hope. The janitor test loads THIS file and asserts both the
# task and this registration.
require 'foreman/cron'
Foreman::Cron.register(:hourly, 'foreman_hyperv:bootdisk_janitor')

Rake::Task[:test].enhance ['test:foreman_hyperv']
