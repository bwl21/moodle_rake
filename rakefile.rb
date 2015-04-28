# This rakefile provides some support to handle multiple moodle instances
# on a given webserver
# see readme for details.

SCRIPT_ROOT        = File.dirname(__FILE__)
BACKUP_FOLDER      = %Q{#{SCRIPT_ROOT}/../moodle_backups}

# these dirs are used for restore

MOODLE_CODE_DIR    = "moodle_code"
INSTALL_CONFIG_DIR = "install_config"
TEMP_DIR           = 'tmp'


class MoodleRakeHelper

  def initialize
    @scriptroot = SCRIPT_ROOT
  end

  def doBackup(instance)
    puts "starting to backup #{instance}"
  end

  def getInstanceNames
    candidates = Dir["#{@scriptroot}/../*/config.php"]
    instances  = candidates.map { |candidate| getInstanceName(candidate) }.compact
    instances
  end

  def getInstanceName(candidate)
    result = nil
    result = File.basename(File.dirname(candidate)) if isInstance?(candidate)
  end

  def isInstance?(candidate)
    begin
      config = File.open(candidate).read
      result = false
      result = true if config.include?("<?php  // Moodle configuration file")
    rescue Exception => e
      throw "could not read instance config: #{e.message}"
    end

  end

  def loadInstance(instance)
    config_filename = "#{@scriptroot}/../#{instance}/config.php"
    throw "not a valid moodle instance: #{instance}" unless isInstance?(config_filename)

    result = MoodleInstance.new(instance, config_filename)

    result
  end

  def loadInstanceConfig

  end

end

class MoodleInstance

  def initialize(name, configfilename)
    @attributes              = {}
    @attributes[:name]       = name
    @attributes[:moodlecode] = File.dirname(configfilename)

    # backup filestrategy is defined here.
    @timestamp               = Time.now.strftime("%Y-%m-%d_%H%M%S")
    @backupdir               = BACKUP_FOLDER

    FileUtils.mkdir_p(@backupdir)
    @backupbase = %Q{#{@backupdir}/#{@attributes[:name]}_#{@timestamp}}

    parse(configfilename)
  end


  def to_s
    "Moodle Instance: #{attributes[:name]}"
  end

  def backup_database

    #todo handle db prefix
    #todo proper error handling

    dbuser = @attributes[:dbuser]
    dbhost = @attributes[:dbhost]
    dbpass = @attributes[:dbpass]
    dbname = @attributes[:dbname]

    # see https://docs.moodle.org/20/en/Site_backup

    cmd    = %Q{mysqldump -u #{dbuser} -h'#{dbhost}' -p'#{dbpass}' -C -Q -e --create-options '#{dbname}' | gzip -9 > '#{mk_backup_filename('database')}'}
    system cmd

    nil
  end

  def backup_files

    #todo handle db prefix
    #todo proper error handling

    dataroot = @attributes[:dataroot]

    dataroot_dirname = File.dirname(dataroot)
    dataroot_files   = File.basename(dataroot)

    cd(dataroot_dirname) do
      cmd = %Q{tar -cvzf '#{mk_backup_filename('files')}' '#{dataroot_files}'}
      system cmd
    end
    nil
  end

  def backup_moodlecode
    moodlecode = @attributes[:moodlecode]

    cmd = %Q{tar -cvzf #{mk_backup_filename('moodlecode')} '#{moodlecode}'}
    system cmd

    nil
  end

  def [](key)
    @attributes[key]
  end

  private

  def mk_backup_filename(part)
    %Q{#{@backupbase}_#{part}.gz}
  end

  def parse(configfilename)
    config        = File.open(configfilename).read
    entrypatterrn = /\$CFG->(\w+) \s*=\s*'  ([^']+)  ';/x

    config.scan(entrypatterrn).each do |match|
      @attributes[match[0].to_sym] = match[1]
    end

    nil
  end

end

@moodle = MoodleRakeHelper.new

################################################################


desc "this help"
task :default do
  sh 'rake -T'
end


desc 'show instances'
task :showInstances do
  puts @moodle.getInstanceNames
end

desc 'show available backups'
task :showBackups do
  backupfiles = Dir["#{BACKUP_FOLDER}/*_files.gz"]
  backupnames = backupfiles.map { |f| File.basename(f, "_files.gz") }
  puts backupnames
end


desc 'backup data and code  an instance'
task :backup, [:instance] do |task, args|
  begin
    instance = @moodle.loadInstance(args[:instance])
    puts "instance found: #{args[:instance]}"

    instance.backup_database
    instance.backup_files
    instance.backup_moodlecode

    # rescue Exception => e
    #   puts "not a valid moodle instance: #{args[:instance]}"
    #   puts e
    #   puts caller
  end
end


desc 'backup data an instance'
task :backupData, [:instance] do |task, args|
  begin
    instance = @moodle.loadInstance(args[:instance])
    puts "instance found: #{args[:instance]}"

    instance.backup_database
    instance.backup_files

    # rescue Exception => e
    #   puts "not a valid moodle instance: #{args[:instance]}"
    #   puts e
    #   puts caller
  end
end


desc 'backup code of an instance'
task :backupCode, [:instance] do |task, args|
  begin
    instance = @moodle.loadInstance(args[:instance])
    puts "instance found: #{args[:instance]}"

    instance.backup_moodlecode

    # rescue Exception => e
    #   puts "not a valid moodle instance: #{args[:instance]}"
    #   puts e
    #   puts caller
  end
end


desc 'restore moodle instance from backup'
task :restore, [:backup] do |task, args|
  target_config_filename = "install_config/config.php"
  moodle_target_instance = MoodleInstance.new("", target_config_filename)
  backupname             = args[:backup]

  system "rm -rf #{TEMP_DIR}" if File.directory?(TEMP_DIR)
  FileUtils.mkdir_p(TEMP_DIR)

  backupfiles = ['files', 'database', 'moodlecode'].inject({}) { |result, value|
    result[value] = Dir["#{BACKUP_FOLDER}/#{backupname}_#{value}.gz"].first
    result
  }


  # cleanup the destination
  system "rm -rf '#{MOODLE_CODE_DIR}'"
  system "rm -rf '#{moodle_target_instance[:dataroot]}'"

  # unpack the files
  cd TEMP_DIR do
    system "tar -vxzf '#{backupfiles['files']}'"
    got_data_folder = Dir["*"].first
    system "mv '#{got_data_folder}' '#{moodle_target_instance[:dataroot]}'"

    system "tar -vxzf '#{backupfiles['moodlecode']}'"
    got_code_folder = Dir["*"].first

    moodle_source_instance = MoodleInstance.new("source", "#{got_code_folder}/config.php")
    system "mv '#{got_code_folder}' '../#{MOODLE_CODE_DIR}'"

    system "gunzip -c  '#{backupfiles['database']}' > database.sql"

    # patch the url
    sql = File.open('database.sql').read
    File.open('database_target.sql', "w") do |f|
      f.puts sql.gsub(moodle_source_instance[:wwwroot], moodle_target_instance[:wwwroot])
    end
  end

  # now import the database
  dbuser = moodle_target_instance[:dbuser]
  dbhost = moodle_target_instance[:dbhost]
  dbpass = moodle_target_instance[:dbpass]
  dbname = moodle_target_instance[:dbname]

  cmd = "mysql --default-character-set=utf8 -u#{dbuser} -p'#{dbpass}' -h#{dbhost} -D#{dbname} < tmp/database_target.sql"
  puts cmd
  system "cmd"

  # finally copy the config file
  cmd = "cp '#{target_config_filename}' '#{MOODLE_CODE_DIR}/config.php'"
  puts cmd
  system cmd
end


