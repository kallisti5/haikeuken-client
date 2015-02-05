#!/bin/ruby

# Haikeuken buildslave script
##############################################
# Copyright 2014 - 2015 Alexander von Gluck IV
# Released under the terms of the GPLv3
##############################################

@version = "0.2"
@rest_period = 5.0

##########################################
# Requirements
##########################################
require 'json'
require 'net/http'
require 'yaml'
require 'open3'

if Gem::Specification::find_all_by_name('colorize').any?
	require 'colorize'
	@color_support = true
else
	@color_support = false
end
##########################################


##########################################
# Helper functions
def warning(message)
	if @color_support
		puts "Warning: #{message}".colorize(:yellow)
	else
		puts "Warning: #{message}"
	end
end

def error(message)
	if @color_support
		puts "Error: #{message}".colorize(:red)
	else
		puts "Error: #{message}"
	end
	exit 1
end
#
##########################################


puts ' _   _       _ _              _               '
puts '| | | |     (_) |            | |              '
puts '| |_| | __ _ _| | _____ _   _| | _____ _ __   '
puts '|  _  |/ _` | | |/ / _ \ | | | |/ / _ \ \'_ \ '
puts '| | | | (_| | |   <  __/ |_| |   <  __/ | | | '
puts '\_| |_/\__,_|_|_|\_\___|\__,_|_|\_\___|_| |_| '
puts '--------------------------------------------- '
puts '         The Haiku package builder            '
puts "                Version #{@version}"
puts ''

# Load some basic platform info
hostname, status_host = Open3.capture2e("uname -n")
platform, status_os = Open3.capture2e("uname -s")
architecture, status_arch = Open3.capture2e("uname -m")

if status_host && status_os && status_arch
	# Clean up vars
	hostname.delete!("\n")
	platform.delete!("\n")
	architecture.delete!("\n")
	puts "Starting buildslave on #{hostname} (#{platform}, #{architecture})"
else
	error("Error pulling machine information!")
end

begin
	if platform == "Linux"
		settings_dir, status = Open3.capture2e("echo -n ~")
		warning("Running on Linux. We don't support non-native platforms yet.")
	elsif platform == "Haiku"
		settings_dir, status = Open3.capture2e("finddir", "B_USER_SETTINGS_DIRECTORY")
		settings_dir.delete!("\n")
	end
	# Load settings YAML
	@settings = YAML::load_file("#{settings_dir}/haikeuken.yml")
rescue
	error("Problem loading configuration file at #{settings_dir}/haikeuken.yml")
end

@remote_uri = "#{@settings['server']['url']}/builders/#{hostname}"
@porter_arguments = "-y -v --no-dependencies"

#puts @settings.inspect

def getwork()
	uri = URI("#{@remote_uri}/getwork?token=#{@settings['general']['token']}")
	begin
		json = JSON.parse(Net::HTTP.get(uri))
	rescue
		puts "=========================================="
		puts "Error: Server #{uri}"
		puts "  Returned invalid JSON data!"
		return nil
	end
	return json
end


def putwork(status, buildlog, build_id)
	uri = URI("#{@remote_uri}/putwork")

	#log = File.open(buildlog, "rb")

	begin
		Net::HTTP.post_form uri, {"token" => @settings['general']['token'],
			"status" => status, "build_id" => build_id,
			"result" => buildlog}
		#Net::HTTP.start(uri.hostname, uri.port) do |http|
		#	http.request(req)
		#end
	rescue
		puts "=========================================="
		puts "Error: Server #{uri}"
		puts "=========================================="
		#log.close
		return nil
	end
	#log.close
end


def refrepo()
	# Clone or update haikuporter
	if ! Dir.exists?("./haikuporter")
		system 'git clone https://bitbucket.org/haikuports/haikuporter.git ./haikuporter'
	else
		Dir.chdir("./haikuporter")
		system 'git pull --rebase'
		Dir.chdir(@settings['general']['work_path'])
	end

	# Check for haikuporter
	if ! File.exist?("./haikuporter/haikuporter")
		puts "Haikuporter missing after clone / update!"
		exit 1
	end

	# Clone or update haikuports
	if ! Dir.exists?("./haikuports")
		system 'git clone https://bitbucket.org/haikuports/haikuports.git ./haikuports'
	else
		Dir.chdir("./haikuports")
		system 'git pull --rebase'
		Dir.chdir(@settings['general']['work_path'])
	end
end


def loop()
	puts "+ Checking for new work..."

	work = getwork()

	# The server could also return a list of tasks,
	# and we could do work.each. For now we just
	# do one task.

	if work == nil or work.count == 0
		puts "- No work available"
		return 0
	end
	
	work.each do |task|
		puts "+ Work received"
		#worklog = "/tmp/#{task['name']}-#{task['version']}-#{task['revision']}.log"
		puts "+ Building #{task['name']}-#{task['version']}-#{task['revision']}"
		worklog, result = Open3.capture2e("#{@settings['general']['work_path']}/haikuporter/haikuporter",
			@porter_arguments, "#{task['name']}-#{task['version']}")
		#result = system "#{@settings['general']['work_path']}/haikuporter/haikuporter #{@porter_arguments} #{task['name']}-#{task['version']} &> #{worklog}"
		status = result ? "OK" : "Fail"
		putwork(status, worklog, task['id'])
    end
end

puts "Haiku Package Build System Client #{@version}"
puts "  Server: #{@settings['server']['url']}"
puts "  Threads: #{@settings['general']['threads']}"
puts "  Work Path: #{@settings['general']['work_path']}"
puts ""
puts "+ Entering main work loop..."

# Create work_path if it doesn't exist
if ! Dir.exists?(@settings['general']['work_path'])
	Dir.mkdir(@settings['general']['work_path'])
end
Dir.chdir(@settings['general']['work_path'])
	
while(1)
	# Disabled for testing
	#puts "+ Refreshing repos..."
	#refrepo()

	loop()
	puts "+ Resting for #{@rest_period} seconds..."
	sleep(@rest_period)
end
