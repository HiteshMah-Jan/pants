if Rails.env.production?
  def fire_up_those_scheduled_tasks!
    Rails.logger.info "Firing up scheduled tasks..."

    Thread.new do
      # timers = Timers::Group.new
      # timers.every(1.minute) { BatchUserPoller.perform }
      # loop { timers.wait }

      loop do
        # Sleep between 30 and 90 seconds, just because we can.
        sleep(rand(30..90))

        # Poll users!
        BatchUserPoller.perform
      end
    end
  end

  # Ensure the jobs run only in a web server.
  if defined?(Rails::Server)
    fire_up_those_scheduled_tasks!
  end

  # Make this thing work in Passenger, too.
  if defined?(PhusionPassenger)
    PhusionPassenger.on_event(:starting_worker_process) do |forked|
      fire_up_those_scheduled_tasks!
    end
  end
end
