require_relative 'system'

module Moonshot
  class ASG # rubocop:disable Metrics/ClassLength
    include Moonshot::CredsHelper

    def initialize(resources)
      @resources = resources
      @ilog = @resources.ilog
      @ssh_user = ENV['CDB_CI_USER'] || ENV['LOGNAME']
    end

    def asg
      @asg ||= Aws::AutoScaling::AutoScalingGroup.new(name: name)
    end

    def rotate_asg_instances
      @ilog.start_threaded('Rotating ASG instances...') do |step|
        @step = step
        @volumes_to_delete = outdated_volumes(outdated_instances)
        @shutdown_instances = cycle_instances(outdated_instances)
        @step.success('ASG instances rotated successfully.')
      end
    end

    def teardown_outdated_instances
      @ilog.start_threaded('Tearing down outdated instances...') do |step|
        @step = step
        terminate_instances(@shutdown_instances)
        reap_volumes(@volumes_to_delete)
        @step.success('Outdated instances removed successfully!')
      end
    end

    def name
      @resources.controller.stack
                .resources_of_type('AWS::AutoScaling::AutoScalingGroup')
                .first.physical_resource_id
    end

    # Retrieves the instances currently in the ASG.
    #
    # @return [Array]
    def instances
      asg.instances
    end

    # Retrieves the current ASG launch configuration name.
    #
    # @return [String]
    def launch_configuration_name
      asg.launch_configuration_name
    end

    def outdated_instances
      instances.reject do |i|
        i.launch_configuration_name == launch_configuration_name
      end
    end

    def outdated_volumes(instances = outdated_instances)
      volumes = []
      instances.each do |i|
        begin
          inst = Aws::EC2::Instance.new(id: i.id)
          volumes << inst.block_device_mappings.first.ebs.volume_id
        rescue StandardError => e
          # We're catching all errors here, because failing to reap a volume
          # is not a critical error, will not cause issues with the release.
          @step.failure('Failed to get volumes for instance '\
                    "#{i.instance_id}: #{e.message}")
        end
      end
      volumes
    end

    # Cycle the instances in the ASG.
    #
    # Each instance will be detached one at a time, waiting for the new instance
    # to be ready before stopping the worker and terminating the instance.
    #
    # @param instances [Array] (outdated instances)
    #   List of instances to cycle. Defaults to all instances with outdated
    #   launch configurations.
    # @return [Array] (array of Aws::AutoScaling::Instance)
    #   List of shutdown instances.
    def cycle_instances(instances = outdated_instances)
      shutdown_instances = []

      if instances.empty?
        @step.success('No instances cycled.')
        return []
      end

      @step.success("Cycling #{instances.size} of #{self.instances.size} " \
                   "instances in #{name}...")

      # Iterate over the instances in the stack, detaching and terminating each
      # one.
      instances.each do |i|
        next if %w(Terminating Terminated).include?(i.lifecycle_state)

        wait_for_instance(i)
        detach_instance(i)

        @step.success("Shutting down #{i.instance_id}")
        shutdown_instance(i.instance_id)
        shutdown_instances << i
      end

      @step.success('All instances cycled.')

      shutdown_instances
    end

    # Waits for an instance to reach a ready state.
    #
    # @param instance [Aws::AutoScaling::Instance] Auto scaling instance to wait
    #   for.
    def wait_for_instance(instance, state = 'InService')
      instance.wait_until(max_attempts: 60, delay: 10) do |i|
        i.lifecycle_state == state
      end
    end

    # Detach an instance from its ASG. Re-attach if failed.
    #
    # @param instance [Aws::AutoScaling::Instance] Instance to detach.
    def detach_instance(instance)
      @step.success("Detaching instance: #{instance.instance_id}")

      # If the ASG can't be brought up to capacity, re-attach the instance.
      begin
        instance.detach(should_decrement_desired_capacity: false)
        @step.success('- Waiting for the AutoScaling '\
                     'Group to be up to capacity')
        wait_for_capacity
      rescue StandardError => e
        @step.failure("Error bringing the ASG up to capacity: #{e.message}")
        @step.failure("Attaching instance: #{instance.instance_id}")
        reattach_instance(instance)
        raise e
      end
    end

    # Re-attach an instance to its ASG.
    #
    # @param instance [Aws::AutoScaling::Instance] Instance to re-attach.
    def reattach_instance(instance)
      instance.load
      return unless instance.data.nil? \
        || %w(Detached Detaching).include?(instance.lifecycle_state)

      until instance.data.nil? || instance.lifecycle_state == 'Detached'
        sleep 10
        instance.load
      end
      instance.attach
    end

    # Terminate instances.
    #
    # @param instances [Array] (instances for termination)
    #   List of instances to terminate. Defaults to all instances with outdated
    #   launch configurations.
    def terminate_instances(instances = outdated_instances)
      if instances.any?
        @step.continue(
          "Terminating #{instances.size} outdated instances..."
        )
      end
      instances.each do |asg_instance|
        instance = Aws::EC2::Instance.new(asg_instance.instance_id)
        begin
          instance.load
        rescue Aws::EC2::Errors::InvalidInstanceIDNotFound
          next
        end

        next unless %w(stopping stopped).include?(instance.state.name)

        instance.wait_until_stopped

        @step.continue("Terminating #{instance.instance_id}")
        instance.terminate
      end
    end

    def reap_volumes(volumes)
      volumes.each do |volume_id|
        begin
          @step.continue("Deleting volume: #{volume_id}")
          ec2_client(region: ENV['AWS_REGION'])
            .delete_volume(volume_id: volume_id)
        rescue StandardError => e
          # We're catching all errors here, because failing to reap a volume
          # is not a critical error, will not cause issues with the release.
          @step.failure("Failed to delete volume #{volume_id}: #{e.message}")
        end
      end
    end

    # Waits for the ASG to reach the desired capacity.
    def wait_for_capacity
      @step.continue(
        'Replacing outdated instances with new instances for the AutoScaling Group...'
      )
      # While we wait for the asg to reach capacity, report instance statuses
      # to the user.
      before_wait = proc do
        instances = []
        asg.reload.instances.each do |i|
          instances << " #{i.instance_id} (#{i.lifecycle_state})"
        end

        @step.continue("Instances: #{instances.join(', ')}")
      end

      asg.reload.wait_until(before_wait: before_wait, max_attempts: 60,
                            delay: 30) do |a|
        instances_up = a.instances.select do |i|
          i.lifecycle_state == 'InService'
        end
        instances_up.length == a.desired_capacity
      end
      @step.success('AutoScaling Group up to capacity!')
    end

    # Shuts down an instance, waiting for the worker to stop processing requests
    # first. We do this instead of using the API so that
    # services will be stopped properly.
    #
    # @param id [String] ID of the instance to terminate.
    def shutdown_instance(id)
      instance = Aws::EC2::Instance.new(id: id)
      options = [
        'UserKnownHostsFile=/dev/null',
        'StrictHostKeyChecking=no'
      ]
      remote = "#{@ssh_user}@#{instance.public_dns_name}"
      cmd = "'sudo shutdown -h now'"
      remote_cmd = "ssh -o #{options.join(' -o ')} #{remote} #{cmd}"

      sys_args = { raise_on_failure: false }
      if @log_file
        sys_args[:echo] = @log_file.nil?
        sys_args[:log_file] = File.new(@log_file, 'a')
      end
      System.exec(remote_cmd, sys_args)
    end
  end
end
