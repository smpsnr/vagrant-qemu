require 'securerandom'

require "vagrant/util/busy"
require "vagrant/util/subprocess"

require_relative "plugin"

module VagrantPlugins
  module QEMU
	  class Driver
      # @return [String] VM ID
      attr_reader :vm_id
      attr_reader :data_dir

      def initialize(id, dir)
        @vm_id = id
        @data_dir = dir
      end

      def get_current_state
        case
        when running?
          :running
        when created?
          :stopped
        else
          :not_created
        end
      end

      def delete
        if created?
          id_dir = @data_dir.join(@vm_id)
          FileUtils.rm_rf(id_dir)
        end
      end

      def start(options)
        if !running?
          id_dir = @data_dir.join(@vm_id)
          image_path = id_dir.join("linked-box.img")
          unix_socket_path = id_dir.join("qemu_socket")
          pid_file = id_dir.join("qemu.pid")

          cmd = []
          cmd += %W(system-system-#{options[:arch]})

          # basic
          cmd += %W(-machine #{options[:machine]})
          cmd += %W(-cpu #{options[:cpu]})
          cmd += %W(-smp #{options[:smp]})
          cmd += %W(-m #{options[:memory]})
          cmd += %W(-device virtio-net-device,netdev=net0)
          cmd += %W(-netdev user,id=net0,hostfwd=tcp::#{options[:ssh_port]}-:22)
          cmd += %W(-nographic)

          # drive
          cmd += %W(-drive "if=virtio,format=qcow2,file=#{image_path}")
          if options[:arch] == "aarch64"
            fm1_path = id_dir.join("edk2-aarch64-code.fd")
            fm2_path = id_dir.join("edk2-arm-vars.fd")
            cmd += %W(-drive "if=pflash,format=raw,file=#{fm1_path},readonly=on")
            cmd += %W(-drive "if=pflash,format=raw,file=#{fm2_path}")
          end

          # control
          cmd += %W(-chardev socket,id=mon0,path=#{unix_socket_path},server,nowait)
          cmd += %W(-mon chardev=mon0,mode=readline)
          cmd += %W(-pidfile #{pid_file})
          cmd += %W(-daemonize)

          execute(cmd)
        end
      end

      def stop
        if running?
          unix_socket_path = id_dir.join("qemu_socket")
          execute("nc", "-U", unix_socket_path) do |type, data|
          case type
          when :stdin
            data.write("system_powerdown")
            data.close
          end
        end
        end
      end

      def import(options)
        new_id = SecureRandom.urlsafe_base64(8)

        # Make dir
        id_dir = @data_dir.join(new_id)
        FileUtils.mkdir_p(id_dir)

        # Prepare firmware
        execute("cp", options[:qemu_dir].join("edk2-aarch64-code.fd"), id_dir.join("edk2-aarch64-code.fd"))
        execute("cp", options[:qemu_dir].join("edk2-arm-vars.fd"), id_dir.join("edk2-arm-vars.fd"))

        # Create image
        execute("qemu-img", "create", "-f", "qcow2", "-b", options[:image_path], id_dir.join("linked-box.img"))

        server = {
          :id => new_id,
        }
      end

      def created?
        result = @data_dir.join(@vm_id).directory?
      end

      def running?
        pid_file = @data_dir.join(@vm_id).join("qemu.pid")
        return false if !pid_file.file?

        begin
          Process.getpgid(File.read(pid_file).to_i)
          true
        rescue Errno::ESRCH
          false
        end
      end

      def execute(*cmd, **opts, &block)
        # Append in the options for subprocess
        cmd << { notify: [:stdout, :stderr, :stdin] }

        interrupted  = false
        int_callback = ->{ interrupted = true }
        result = ::Vagrant::Util::Busy.busy(int_callback) do
          ::Vagrant::Util::Subprocess.execute(*cmd, &block)
        end

        result.stderr.gsub!("\r\n", "\n")
        result.stdout.gsub!("\r\n", "\n")

        if result.exit_code != 0 && !interrupted
          raise Errors::ExecuteError,
            command: cmd.inspect,
            stderr: result.stderr,
            stdout: result.stdout
        end

        if opts
          if opts[:with_stderr]
            return result.stdout + " " + result.stderr
          else
            return result.stdout
          end
        end
      end
    end
  end
end