require 'set'
require 'sequel'
require 'yaml'
require 'mimemagic'
require 'shellwords'
require 'fileutils'
require 'tempfile'


def file_action(local_path)
  return :ignore unless File.exist? local_path

  File.open(local_path) do |f|
    mime = MimeMagic.by_magic(f)
    case
    when $target['supported_mime'].include?(mime.to_s.chomp)
      :copy
    when mime.audio?
      :transcode
    else
      :ignore
    end
  end
end

def copy(local_path, remote_path)
  puts "Copy: #{local_path} -> #{remote_path}"
  FileUtils.mkdir_p(File.dirname(remote_path))
  FileUtils.copy_file local_path, remote_path
end

def transcode(local_path, remote_path)
  cmd = [
    ($config['ffmpeg'] || 'ffmpeg'),
    '-i', local_path,
    *Shellwords.split($target['transcode']['ffmpeg']),
    remote_path,
    err: [:child, :out]
  ]

  puts "Transcode: #{local_path} -> #{remote_path}"
  FileUtils.mkdir_p(File.dirname(remote_path))
  err = nil
  IO.popen(cmd) do |io|
    err = io.read
  end
  unless $?.success?
    raise "Transcoding failed:\n#{err}\n"
  end
end

$config = YAML.load(File.read(ARGV.first))
$target = $config['target']

if $target.key? 'mtp'
  serial, path = $target['mtp'].split('/', 2)

  dev = Dir['/sys/bus/usb/devices/*'].find do |usb_path|
    serial_path = "#{usb_path}/serial"
    File.exist?(serial_path) && File.read(serial_path).chomp == serial
  end
  raise "No USB device found with Serial number #{serial}" if dev.nil?

  bus_num = File.read("#{dev}/busnum").chomp.rjust(3, '0')
  dev_num = File.read("#{dev}/devnum").chomp.rjust(3, '0')

  mtp_name = "%5Busb%3A#{bus_num}%2C#{dev_num}%5D"

  # try to mount
  err = IO.popen(['gio', 'mount', "mtp://#{mtp_name}", err: [:child, :out]]).read

  mtp_path = "/run/user/#{Process.uid}/gvfs/mtp:host=#{mtp_name}"
  unless File.exist? mtp_path
    raise "Failed to mount MTP device: #{err}"
  end

  target_path = "#{mtp_path}/#{path}"
else
  target_path = $target['path']
end

music_path = "#{target_path}/#{$target['folders']['music']}"

raise 'No target path configured' if target_path.nil?

db = Sequel.connect "sqlite://#{ENV['HOME']}/.config/banshee-1/banshee.db"

copy_queue = Queue.new
transcode_queue = Queue.new

to_delete = []
at_exit do
  to_delete.each do |fn|
    if File.exist? fn
      puts "Deleting: " << fn
      File.delete fn
    end
  end
end

Thread.abort_on_exception = true

copy_thread = Thread.start do
  loop do
    local_path, remote_path, opts = copy_queue.pop
    break if local_path.nil?
    raise local_path if local_path.is_a? Exception

    to_delete << remote_path
    copy(local_path, remote_path)
    to_delete.delete remote_path

    unless opts.nil?
      if opts[:delete]
        puts "Deleting: " << local_path
        File.delete local_path
        to_delete.delete local_path
      end

      if opts[:waiter]
        opts[:waiter] << nil
      end
    end
  end
end

transcode_threads = 8.times.map do
  Thread.start do
    waiter = Queue.new
    loop do
      local_path, remote_path = transcode_queue.pop
      break if local_path.nil?
      
      # transcode to /tmp
      tmp_filename = "#{Dir::Tmpname.make_tmpname('/tmp/', nil)}.#{$target['transcode']['extension']}"
      to_delete << tmp_filename
      begin
        transcode local_path, tmp_filename
      rescue => ex
        copy_queue << ex
        break
      end

      # place in queue to copy
      copy_queue << [tmp_filename, remote_path, delete: true, waiter: waiter]

      # wait for file to be copied
      waiter.pop
    end
  end
end

db[:CoreTracks].each do |track|
  uri = URI(track[:Uri])
  next unless uri.scheme == 'file'

  source_path = $config['source'].gsub(%r(/+), '/').sub(%r(/$), '')
  local_path  = URI.unescape(uri.path).gsub(%r(/+), '/').sub(%r(/$), '')
  rel_path    = local_path.sub(%r(^#{source_path}/), '')
  # ignore paths outside of the given source directory
  next if local_path == rel_path
  # ignore excluded paths
  next if $config['exclude'].map { |e| e.gsub(%r(/+), '/').sub(%r(/$), '') }.any? { |e| rel_path == e || rel_path.start_with?("#{e}/") }

  remote_path = "#{music_path}/#{rel_path}"
  unless File.exist? remote_path
    path, ext = rel_path.split(/\.([^.]*)$/)
    remote_path = "#{music_path}/#{path}"
    if ext == $target['transcode']['extension'] || !File.exist?("#{remote_path}.#{$target['transcode']['extension']}")
      case file_action(local_path)
      when :copy
        copy_queue << [local_path, "#{remote_path}.#{ext}"]
      when :transcode
        transcode_queue << [local_path, "#{remote_path}.#{$target['transcode']['extension']}"]
      when :ignore
        puts "Ignore: " << local_path
      end
    end
  end
end

8.times do
  transcode_queue << nil
end
8.times do
  transcode_threads.each(&:join)
end
copy_queue << nil
copy_thread.join
