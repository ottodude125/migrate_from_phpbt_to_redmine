
############### INTRODUCTION ###############

# This rake task was written to migrate a phpBugTracker 1.0.5 mysql database
# to a Redmine 2.5 mysql database. It has not been tested with any other configuration
# and therefore I have no idea if it will work or not. I am making this available
# as an example of how I migrated my database. The exact configuration in this
# script may not meet your exact needs and therefore it is highly recommended that
# you read through the entire script and updated it accordingly. Some items I stole
# from the migrate_from_mantis.rake script that was included with the Redmine 2.5
# distribution.

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.


############### NOTES AND REQUIREMENTS ###############

# 1) My phpbt db consisted of ~70,000 records. The import would take approximately
# 30 minutes to complete. To provide some informative feedback during this process 
# I implemented a progress bar with each table imported. This progress bar is one of 
# include statements. To find more information on the bar you can go to
# https://github.com/paul/progress_bar. Before you run this scrip you need to either 
# comment out those lines that set up the bar or you need to install the gem. 
# As of Redmine 2.5 you can add private gems to Gemfile.local and then rebundle.

# 2) If rake is unable to import a user it will alert you of what users it was unable
# to import.

# 3) If it finds duplicate versions on the same project it will merge them 
# rather than import all version

# 4) When importing issues if the author, or assigned to cannot be found
# the script will automatically assign the admin user. 

# 5) This script assumes you have installed the "Banner" plugin. It will assign
# this module to all projects. If this is not true then update that line in the
# migrate projects section

# 6) When importing comments if issue cannot be found it will skip user. Also
# if created_by cannot be found it assigns Admin user to comment so it is not lost

# 7) When importing cc's it skips the cc if it cannot find the issue or the user.
# No sense importing a cc if we have no idea where or who

# 8) When importing dependency it skips it if it cannot find the bug or the bug it
# depends on

# 9) When importing bug history if the issue cannot be found the history is skipped

# 10) Imported attachments have the original bug id and a "-" appended to front of
# filename. I am not sure if this is normal but all my phpbt attachment files used that
# format for filenames so I programmed it like that so files could be found. 
# Additionally all phpbt files were pulled from their folders and placed in a single
# folder called phpbt_files in the redmine files folder. I did not have any duplicate
# filenames when doing this. You may not be so lucky and therefore may need to alter
# the way this section is imported. 

# 11) We had configured our phpbt to have 10 Severities(Trackers) - three of them matching redmine
# We wanted to maintain this configuration in Redmine but we only wanted the three original
# redmine trackers to be active for all projects. For this reason to run the import
# all trackers are initially assigned to all projects. Once we have completed importing
# all the data we update all projects to use only the feature, bug, and support trackers

# 12) I was having a problem with the rake task complaining that I was trying to assign an
# inactive user to an issue. To work around this all users when first imported are set to active
# I then, once all migrations are completed, update all users to their correct status. 

# 13) Script assumes that you are using LDAP and sets the auth_source_id to 1. If this is not
# true you will need to update accordingly


############### PROCESS I FOLLOWED TO SETUP REDMINE ###############
# I was installing a completely brand new Redmine instance. The only data
# involved was from my phpbt database. This process WILL DELETE any data
# that is currently in your Redmine database.

# 1) Comment out errors.add line in app/models/watcher.rb validate_user method
# 2) Comment out errors.add circular in app/models/issue_relation.rb validate_issue_relation method
# 3) Comment out errors.add fixed version id inclusion line in app/models/issue.rb validate_issue - if fixed_issue method
# 4) Run the following to create and setup the database/app
			# RAILS_ENV=production rake db:drop; RAILS_ENV=production rake db:create; rake generate_secret_token; RAILS_ENV=production rake db:migrate; RAILS_ENV=production rake redmine:plugins:migrate; RAILS_ENV=production rake redmine:load_default_data;
# 5) Log in as admin, go to administration section and:
	# a) Configure all tabs in settings section
	# b) Set up LDAP that all users will use
# 6) Pull the attachment files from phpbt to redmine
			##### ATTACHMENT MIGRATION #####
			# list number of files in directory
			# find ./ -type f | wc -l 
			# Copy all files from phpbt/attachments to redmine
			# find ./ -type f -exec cp -- '{}' "../../redmine/files/phpbt_files" \; 
# 7) Run the following to run this script
			# RAILS_ENV=production rake redmine:migrate_from_phpbt;
# 8) Uncomment out lines in #1, #2, and #3
# 9) Go back to administration section and update users/groups/roles/permissions
# as needed.


# Add color to terminal output
module Colors
  def colorize(text, color_code)
    "\033[#{color_code}m#{text}\033[0m"
  end
  {
    :black => 30,
    :red => 31,
    :green => 32,
    :yellow => 33,
    :blue => 34,
    :magenta => 35,
    :cyan => 36,
    :white => 37
  }.each do |key, color_code|
    define_method key do |text|
      colorize(text, color_code)
    end
  end
end

# Set logger and level rake task
Rails.logger = Logger.new('log/production.log')
Rails.logger.level = 0

desc 'phpbt migration script'

require 'active_record'
require 'iconv' if RUBY_VERSION < '1.9'
require 'pp'
require 'date'
require 'time'

# Special Require for progress bars - https://github.com/paul/progress_bar
require 'progress_bar'

namespace :redmine do
task :migrate_from_phpbt => :environment do

  include Colors

  module PhpbtMigrate

    DEFAULT_STATUS = IssueStatus.default # New
    assigned_status = IssueStatus.find_by_position(2) # In Progress
    resolved_status = IssueStatus.find_by_position(3) # Resolved
    feedback_status = IssueStatus.find_by_position(4) # Feedback
    closed_status = IssueStatus.where(:is_closed => true).first # Closed
    STATUS_MAPPING = {1 => DEFAULT_STATUS,    # opened
                      2 => assigned_status,   # assigned
                      3 => DEFAULT_STATUS,    # proposed
                      4 => assigned_status,   # pending
                      5 => resolved_status,   # resolved
                      6 => closed_status,     # closed
                      }
    
    priorities = IssuePriority.all
    DEFAULT_PRIORITY = priorities[2]
    PRIORITY_MAPPING = {0 => priorities[0], # low
                        1 => priorities[1], # low
                        2 => priorities[2], # normal
                        3 => priorities[3], # high
                        4 => priorities[4], # urgent
                        5 => priorities[5]  # immediate
                        }

    TRACKER_BUG = Tracker.find_by_position(1)     # Bug
    TRACKER_FEATURE = Tracker.find_by_position(2) # Feature
    TRACKER_SUPPORT = Tracker.find_by_position(3) # Support

    VERSION_STATUS_MAPPING = {'true' => 'open', 
                              'false' => 'closed'
                              }

    USER_STATUS_MAPPING = {0 => 3, 
                            1 => 1
                            }


    # Severity Class
    class PhpbtSeverity < ActiveRecord::Base
      self.table_name = :phpbt_severity

    end

   # OS Class
    class PhpbtOS < ActiveRecord::Base
      self.table_name = :phpbt_os

    end

   # Site Class
    class PhpbtSite < ActiveRecord::Base
      self.table_name = :phpbt_site

    end

    # Resolution Class
    class PhpbtResolution < ActiveRecord::Base
      self.table_name = :phpbt_resolution

    end

   # User Class
    class PhpbtUser < ActiveRecord::Base
      self.table_name = :phpbt_auth_user_temp

      # If first_name is blank set it to "unknown<:user_id>"
      def firstname
        @firstname = read_attribute(:first_name).blank? ? "unknown" + read_attribute(:user_id).to_s : read_attribute(:first_name)
        @firstname
      end

      # If last_name is blank set it to "unknown<:user_id>"
      def lastname
        @lastname = read_attribute(:last_name).blank? ? "unknown" + read_attribute(:user_id).to_s : read_attribute(:last_name)
        @lastname
      end

      # If email is not used yet and is valid then use it. Else set to "unknown<:user_id>@foo.bar"
      def get_email
        @email = "unknown" + read_attribute(:user_id).to_s + "@foo.bar"
        if read_attribute(:email).match(/^([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})$/i) &&
             !User.find_by_mail(read_attribute(:email))
          @email = read_attribute(:email)
        end
        @email
      end

      # If login is not taken yet then use it. Else set to "unknown<:user_id>"
      def get_username
        @username = "unknown" + read_attribute(:user_id).to_s
        if !User.find_by_login(read_attribute(:login)[0..29].gsub(/[^a-zA-Z0-9_\-@\.]/, '-'))
          @username = read_attribute(:login)[0..29].gsub(/[^a-zA-Z0-9_\-@\.]/, '-')
        end
        @username
      end
	    
    end

    # Project Class
    class PhpbtProject < ActiveRecord::Base
      self.table_name = :phpbt_project
      has_many :versions, :class_name => "PhpbtVersion", :foreign_key => :project_id

      @@ident_count = 0

      def identifier
        project_name = read_attribute(:project_name).downcase.gsub(/[^a-z0-9\-]+/, '-')
        @identifier = project_name.slice(0, Project::IDENTIFIER_MAX_LENGTH)
        # if identifier already taken then shorten it and add a number on end of string
        if Project.find_by_identifier(@identifier)
          @@ident_count += 1
          @identifier = project_name.slice(0, Project::IDENTIFIER_MAX_LENGTH - 2) + @@ident_count.to_s
        end
        @identifier
      end
    end

    # Version Class
    class PhpbtVersion < ActiveRecord::Base
    	self.table_name = :phpbt_version

    end

    # Bug Class
    class PhpbtBug < ActiveRecord::Base
      self.table_name = :phpbt_bug
      has_many :comments, :class_name => "PhpbtComment", :foreign_key => :bug_id
      has_many :ccs, :class_name => "PhpbtBugCC", :foreign_key => :bug_id
    end
    
    # Comment Class
    class PhpbtComment < ActiveRecord::Base
    	self.table_name = :phpbt_comment
    	belongs_to :bug, :class_name => "PhpbtBug", :foreign_key => :bug_id
    end

    # Bug CC Class
    class PhpbtBugCC < ActiveRecord::Base
    	self.table_name = :phpbt_bug_cc
    	belongs_to :bug, :class_name => "PhpbtBug", :foreign_key => :bug_id
    end

    # Bug Depenency
    class PhpbtBugDependency < ActiveRecord::Base
    	self.table_name = :phpbt_bug_dependency

    end

    # Bug History
    class PhpbtBugHistory < ActiveRecord::Base
    	self.table_name = :phpbt_bug_history
    end

    # Attachment
    class PhpbtAttachment < ActiveRecord::Base
    	self.table_name = :phpbt_attachment
    end


    def self.migrate
    	############### ORDER OF EXCECUTION ###############
      # a) phpbt_status -> issue_statuses - Setup as mapping
      # b) phpbt_priority -> issue_priority - Setup as mapping
      # c) Delete data from all db's 
      # 1) phpbt_severity -> tracker
      # 2a) phpbt_issue closed_in_version -> custom_fields
      # 2b) Add all trackers to closed_in_version custom field
      # 3a) phpbt_issue url -> custom_fields
      # 3b) Add all trackers to url custom field
      # 4a) phpbt_os -> custom_fields
      # 4b) Add all trackers to os custom field
      # 5a) phpbt_site -> custom_fields
      # 5b) Add all trackers to site custom field
      # 6a) phpbt_resoluion -> custom_fields
      # 6b) Add all trackers to resolution custom field
      # 7) phpbt_auth_user -> user
      # 8a) phpbt_project -> project
      # 8b) phpbt_version -> version
			# 9) phpbt_bug -> issue
			# 10) phpbt_comment -> journal
			# 11) phpbt_bug_cc -> watcher
			# 12) phpbt_bug_dependency -> issue_relation
			# 13) phpbt_bug_history -> journal_details
			# 14) phpbt_attachments -> attachments
      # 15) update project tracker association
      # 16) update user statuses


# component
# auth_group
# auth_perm
# group_perm
# user_group
# user_group_orig
# project_group
# project_perm



     
      ###############################################
      ############### DELETE OLD DATA ###############
      ###############################################
      puts "\e[33m" + "Deleting old data. Depending on tables this may take a moment." + "\e[32m"
      CustomField.destroy_all
      User.delete_all "login <> 'admin'"
      Project.destroy_all
			JournalDetail.destroy_all
			Attachment.destroy_all
      Issue.destroy_all
      Tracker.where("name NOT IN (?)", ["Bug", "Feature", "Support"]).destroy_all
      Journal.destroy_all
      Watcher.destroy_all
      CustomValue.destroy_all
      IssueRelation.destroy_all
      IssueFaviconUserSetting.destroy_all
      EnabledModule.destroy_all
      puts

      #################################################################
      ############### PHPBT SEVERITY TO REDMINE TRACKER ###############
      #################################################################
      puts "\e[34m" + "Migrating Phpbt Severity to Redmine Tracker" + "\e[32m"
      bar = ProgressBar.new(PhpbtSeverity.count)
      trackers_map = {}
      severities_migrated = 0
      position = 3
      ActiveRecord::Base.connection.execute('ALTER TABLE trackers AUTO_INCREMENT = 1')
      PhpbtSeverity.all.each do |severity|
        bar.increment!
        if ["Bug", "Feature", "Support"].include?(severity.severity_name)
          trackers_map[severity.severity_id] = Tracker.find_by_name(severity.severity_name).id
          next
        end
        position += 1
        t = Tracker.new :name => encode(severity.severity_name),
                        :position => severity.sort_order + 3,
                        :is_in_roadmap => 1
        next unless t.save!
        severities_migrated += 1
        trackers_map[severity.severity_id] = t.id
      end
      puts
      puts 


      #####################################################################
      ############### CREATE CLOSED IN VERSION CUSTOM FIELD ###############
      #####################################################################
      puts "\e[34m" + "Create Closed In Version Custom Field" + "\e[32m"
      bar = ProgressBar.new(2)
      cf_civ = CustomField.new :field_format => "version",
      							:name => "Closed In Version",
      							:is_required => "0",
      							:is_for_all => "1",
      							:is_filter => "1",
      							:position => 2,
      							:editable => true,
      							:visible => "1",
      							:multiple => "0",
      							:url_pattern => "",
      							:edit_tag_style => ""
      cf_civ.type = "IssueCustomField"
      cf_civ.save!
      bar.increment!
			# Associate all Trackers with closed in version
      @civ_custom_field = CustomField.find(cf_civ.id)
      @civ_custom_field.trackers << Tracker.all
      bar.increment!
      puts
      puts


      #######################################################
      ############### CREATE URL CUSTOM FIELD ###############
      #######################################################
      puts "\e[34m" + "Create URL Custom Field" + "\e[32m"
      bar = ProgressBar.new(2)
      cf_url = CustomField.new :field_format => "string",
      							:name => "URL",
      							:is_required => "0",
      							:is_for_all => "1",
      							:is_filter => "1",
      							:position => 2,
      							:editable => true,
      							:visible => "1",
      							:multiple => "0",
      							:url_pattern => "",
      							:edit_tag_style => ""
      cf_url.type = "IssueCustomField"
      cf_url.save!
      bar.increment!
      # Associate all Trackers with url
      @url_custom_field = CustomField.find(cf_url.id)
      @url_custom_field.trackers << Tracker.all
      bar.increment!
      puts
      puts


      #########################################################
      ############### PHPBT OS TO CUSTOM FIELDS ###############
      #########################################################
      puts "\e[34m" + "Migrating Phpbt Operating Systems To Custom Field" + "\e[32m"
      bar = ProgressBar.new(PhpbtOS.count)
      possible_values = ""
      PhpbtOS.all.each do |os|
        bar.increment!
        possible_values = possible_values + "\r\n" + os.os_name
      end
      cf = CustomField.new :field_format => "list",
                            :name => "Operating System",
                            :description => "",
                            :multiple => "0",
                            :default_value => "All",
                            :url_pattern => "",
                            :edit_tag_style => "",
                            :is_required => "0",
                            :is_for_all => "1",
                            :is_filter => "1",
                            :searchable => "1", 
                            :visible => "1",
                            :position => 1,
                            :editable => true,
                            :possible_values => possible_values
      cf.type = "IssueCustomField"                 
      cf.save!
      
      # Associate all Trackers with operating systems
      @os_custom_field = CustomField.find(cf.id)
      @os_custom_field.trackers << Tracker.all
      puts
      puts


      ###########################################################
      ############### PHPBT SITE TO CUSTOM FIELDS ###############
      ###########################################################
      puts "\e[34m" + "Migrating Phpbt Sites To Custom Field" + "\e[32m"
      bar = ProgressBar.new(PhpbtSite.count)
      possible_values = ""
      PhpbtSite.order("sort_order").each do |site|
        bar.increment!
        possible_values = possible_values + "\r\n" + site.site_name
      end
      s = CustomField.new :field_format => "list",
                          :name => "Site",
                          :description => "",
                          :multiple => "0",
                          :default_value => "All",
                          :url_pattern => "",
                          :edit_tag_style => "",
                          :is_required => "0",
                          :is_for_all => "1",
                          :is_filter => "1",
                          :searchable => "1", 
                          :visible => "1",
                          :position => 1,
                          :editable => true,
                          :possible_values => possible_values
      s.type = "IssueCustomField"                 
      s.save!
      
      # Associate all Trackers with sites
      @site_custom_field = CustomField.find(s.id)
      @site_custom_field.trackers << Tracker.all
      puts
      puts


      #################################################################
      ############### PHPBT RESOLUTION TO CUSTOM FIELDS ###############
      #################################################################
      puts "\e[34m" + "Migrating Phpbt Resolutions to Custom Field" + "\e[32m"
      bar = ProgressBar.new(PhpbtResolution.count)
      possible_values = "None\r\n"
      PhpbtResolution.order("sort_order").each do |resolution|
        bar.increment!
        possible_values = possible_values + "\r\n" + resolution.resolution_name
      end
      r = CustomField.new :field_format => "list",
                          :name => "Resolution",
                          :description => "",
                          :multiple => "0",
                          :default_value => "None",
                          :url_pattern => "",
                          :edit_tag_style => "",
                          :is_required => "0",
                          :is_for_all => "1",
                          :is_filter => "1",
                          :searchable => "1", 
                          :visible => "1",
                          :position => 1,
                          :editable => true,
                          :possible_values => possible_values
      r.type = "IssueCustomField"                 
      r.save!
      
      # Associate all Trackers with resolutions
      @resolution_custom_field = CustomField.find(r.id)
      @resolution_custom_field.trackers << Tracker.all
      puts
      puts


      ###############################################################
      ############### PHPBT AUTH USER TO REDMINE USER ###############
      ###############################################################
      puts "\e[34m" + "Migrating Phpbt Users To Redmine User" + "\e[32m"
      bar = ProgressBar.new(PhpbtUser.count)
      users_map = {}
      users_migrated = 0
      num_duplicate_users = 0
      phpbt_duplicate_users = {}
      phpbt_inactive_users = {}
      PhpbtUser.all.each do |user|
        bar.increment!
      	next unless user.login != "admin"
        begin
	        u = User.new :firstname => encode(user.firstname),
	                     :lastname => encode(user.lastname),
	                     :mail => user.get_email,
	                     :status => 1,
	                     :created_on => encode(Time.at(user.created_date)),
	                     :mail_notification => "only_my_events",
	                     :updated_on => encode(Time.at(user.last_modified_date))
	        u.login = user.get_username
	        u.password = user.password
          u.admin = false
          u.id = user.user_id
          u.save!
          users_migrated += 1
          users_map[user.user_id] = u.id
          u.update_attributes(:auth_source_id => 1)
          phpbt_inactive_users[user.user_id] = u.id unless user.active == 1
	      	# Setup favicon setting for each user
	      	f = IssueFaviconUserSetting.new :user_id => u.id,
	      																	:enabled => 1
	      	f.save
	      rescue
          phpbt_duplicate_users[user.user_id] = user.first_name + " " + user.last_name + " : " + user.email
          num_duplicate_users += 1
	    	end
      end
      puts 
      if num_duplicate_users > 0
        puts "\e[31m" + "The following #{num_duplicate_users} phpBugTracker accounts could not be transfered to Redmine: " + "\e[0m"
        phpbt_duplicate_users.each do |user, info|
          puts "\e[31m" + "id: " + user.to_s + " info: " + info.to_s + "\e[0m"
        end
      end
      puts
      puts


      ################################################################
      ############### PHPBT PROJECT TO REDMINE PROJECT ###############
      ################################################################
      puts "\e[34m" + "Migrating Projects and Versions to Redmine" + "\e[32m"
      bar = ProgressBar.new(PhpbtProject.count)
      projects_map = {}
      versions_map = {}
      num_duplicate_versions = 0
      phpbt_duplicate_versions = {}
      PhpbtProject.all.each do |project|
        bar.increment!
        p = Project.new :name => encode(project.project_name),
                        :description => encode(project.project_desc),
                        :status => encode(project.active),
                        :created_on => encode(Time.at(project.created_date)),
                        :updated_on => encode(Time.at(project.created_date))
        p.identifier = project.identifier
        p.id = project.project_id
        next unless p.save
        projects_map[project.project_id] = p.id
        p.enabled_module_names = ['issue_tracking', 'time_tracking', 'news', 'documents', 'files', 
                                  'wiki', 'repository', 'boards', 'calendar', 'gantt', 'banner']
        
        # Temporarily associate all trackers with this project. After adding bugs we will update this
        # To only use trackers that we want associated. This is to add bugs which use old inactive trackers
        proj = Project.find(p.id)
        proj.trackers.clear
        proj.trackers << Tracker.all
        

        ################################################
        ############### PROJECT VERSIONS ###############
        ################################################
        project.versions.each do |version|
          v = Version.new :name => encode(version.version_name),
          								:description => "",
          								:status => VERSION_STATUS_MAPPING[version.active.to_s],
          								:sharing => "none",
          								:created_on => encode(Time.at(version.created_date)),
          								:updated_on => encode(Time.at(version.last_modified_date))
          v.project = p
          v.id = version.version_id
          # If version instance params invalid and cause is ununique name
          # dont create but still add this version to map to original duplicate version
          if !v.valid?
            if v.errors[:name].size > 0
              redmine_version = Version.find_by_project_id_and_name(p.id, version.version_name)
              versions_map[version.version_id] = redmine_version.id
              phpbt_duplicate_versions[version.version_id] = "PhpbtName: " + version.version_name + " PhpbtProject_id: " + version.project_id.to_s 
              num_duplicate_versions += 1
            end
          else
            v.save
            versions_map[version.version_id] = v.id
          end
        end
      end
      puts
      if num_duplicate_versions > 0
        puts "\e[31m" + "The folowing #{num_duplicate_versions} phpBugTracker versions could not be migrated because they were duplicates. They instead will be merged." + "\e[0m"
        phpbt_duplicate_versions.each do |versions, info|
          puts "\e[31m" + "id: " + versions.to_s + " " + info.to_s + "\e[0m"
        end
      end
      puts
      puts


      ##########################################################
      ############### PHPBT BUG TO REDMINE ISSUE ###############
      ##########################################################
      puts "\e[34m" + "Migrating Bugs" + "\e[32m"
      bar = ProgressBar.new(PhpbtBug.count)
      issues_map = {}
      failed_issues = {}
      errors = ""
      PhpbtBug.find_each(:batch_size => 200) do |bug|
        bar.increment!
        begin
	        i = Issue.new :project_id => bug.project_id,
	        							:subject => encode(bug.title[0..254]),
	                      :description => encode(bug.description),
	                      :priority => PRIORITY_MAPPING[bug.priority] || DEFAULT_PRIORITY,
	                      :created_on => Time.at(bug.created_date),
	                      :updated_on => Time.at(bug.last_modified_date)
	        i.author = User.find(users_map[bug.created_by]) rescue User.find(1)
	        i.fixed_version = Version.find(versions_map[bug.version_id]) unless bug.version_id.blank?
	        i.status = STATUS_MAPPING[bug.status_id] || DEFAULT_STATUS
	        track = Tracker.find(trackers_map[bug.severity_id]) || TRACKER_BUG
	        i.tracker = track
	        i.assigned_to = User.find(users_map[bug.assigned_to]) rescue User.find(1)
	        i.start_date = Time.at(bug.created_date)
	        i.closed_on  = Time.at(bug.close_date)
	        i.id = bug.bug_id
	        i.save(:validate => false)
	        issues_map[bug.bug_id] = i.id
	        iss = Issue.find(i)
	        iss.update_attributes!(:created_on => Time.at(bug.created_date), :updated_on => Time.at(bug.last_modified_date), :closed_on => Time.at(bug.close_date))
	       	#iss.update_column(:updated_on => Time.at(bug.last_modified_date))
	      rescue
	        failed_issues[bug.bug_id] = errors
	      end	      
    
        if !i.nil?
	        # Create custom_field_os
	        os = CustomValue.new :customized_type => "Issue",
	        						:customized_id => i.id,
	        						:custom_field_id => @os_custom_field.id,
	        						:value => PhpbtOS.find(bug.os_id).os_name
	        os.save

	        # Create custom_field_site
	        site = CustomValue.new :customized_type => "Issue",
	        						 :customized_id => i.id,
	        						 :custom_field_id => @site_custom_field.id,
	        						 :value => PhpbtSite.find(bug.site_id).site_name
	        site.save
	        
	        # Create custom_field_resolution
	        if bug.resolution_id > 0
	          resolution = CustomValue.new :customized_type => "Issue",
	          						 		:customized_id => i.id,
	          						 		:custom_field_id => @resolution_custom_field.id,
	          						 		:value => PhpbtResolution.find(bug.resolution_id).resolution_name
	          resolution.save
	        end

	        # Create custom_field_closed_in_version
	        if bug.closed_in_version_id > 0
	          version = CustomValue.new :customized_type => "Issue",
	          						 		:customized_id => i.id,
	          						 		:custom_field_id => @civ_custom_field.id,
	          						 		:value => PhpbtVersion.find(bug.closed_in_version_id).version_name
	          version.save
	        end

	        # Create custom_field_url
	        if bug.url != ""
	          seturl = CustomValue.new :customized_type => "Issue",
	          						 							:customized_id => i.id,
	          						 							:custom_field_id => @url_custom_field.id,
	          						 							:value => bug.url
	          seturl.save
	        end
	      end
      end
      puts 
      puts
 			

      ##############################################################
      ############### PHPBT BUG COMMENTS TO JOURNALS ###############
      ##############################################################
      puts "\e[34m" + "Migrating Comments" + "\e[32m"
      bar = ProgressBar.new(PhpbtComment.count)
      PhpbtComment.all.each do |comment|
      	bar.increment!
      	# If bug_id not in map then skip - cant import comments unless we have an issue
      	next unless issues_map[comment.bug_id]
      	# If come accross invalid user id then set user as admin so we dont loose comment
      	user_id = User.find(users_map[comment.created_by]).id rescue User.find(1).id
        j = Journal.new :journalized_type => "Issue",
        								:user_id => user_id,
        								:notes => encode(comment.comment_text),
        								:created_on => Time.at(comment.created_date)
        
        j.journalized_id = Issue.find(issues_map[comment.bug_id]).id# rescue Issue.first.id
				j.id = comment.comment_id
				j.save
      end
      puts
      puts


      ######################################################
      ############### PHP BUG CC TO WATCHERS ###############
      ######################################################
      puts "\e[34m" + "Migrating Bug CC's" + "\e[32m"
      bar = ProgressBar.new(PhpbtBugCC.count)
      PhpbtBugCC.all.each do |bug_cc|
        bar.increment!
      	next unless issues_map[bug_cc.bug_id] && users_map[bug_cc.user_id]
       	u = User.find(users_map[bug_cc.user_id]) rescue User.find(1)
       	i = Issue.find_by_id(issues_map[bug_cc.bug_id])
        i.add_watcher(u)
      end
      puts 
      puts 


      #######################################################################
      ############### PHPBT BUG DEPENDENCY TO ISSUE RELATIONS ###############
      #######################################################################
      puts "\e[34m" + "Migrating Bug Depenency" + "\e[32m"
      bar = ProgressBar.new(PhpbtBugDependency.count)
      PhpbtBugDependency.all.each do |dependency|
        bar.increment!
        next unless issues_map[dependency.bug_id] && issues_map[dependency.depends_on]
        d = IssueRelation.new :relation_type => IssueRelation::TYPE_RELATES
        d.issue_from = Issue.find_by_id(issues_map[dependency.bug_id])
        d.issue_to = Issue.find_by_id(issues_map[dependency.depends_on])
        d.save
      end
      puts 
      puts
      

      ####################################################################
      ############### PHPBT BUG HISTORY TO JOURNAL DETAILS ###############
      ####################################################################
      puts "\e[34m" + "Migrating Bug History" + "\e[32m"
      bar = ProgressBar.new(PhpbtBugHistory.count)
      PhpbtBugHistory.all.each do |history|
        bar.increment!
      	# If bug_id not in map then skip - cant import history unless we have an issue
        begin
					issue = Issue.find(issues_map[history.bug_id])
        rescue
        	next
        end
        jd = JournalDetail.new :journal_id => issues_map[history.bug_id],
        												:property => "attr",
        												:prop_key => "map to changed_field",
        												:old_value => history.old_value,
        												:value => history.new_value
        jd.save
      end
      puts 
      puts


      ####################################################################
      ############### PHPBT BUG ATTACHMENTS TO ATTACHMENTS ###############
      ####################################################################
      puts "\e[34m" + "Migrating Attachments" + "\e[32m"
      bar = ProgressBar.new(PhpbtAttachment.count)
      PhpbtAttachment.all.each do |attachment|
      	bar.increment!
      	# If bug_id not in map then skip - cant import attachment unless we have an issue
        begin
					issue = Issue.find(issues_map[attachment.bug_id])
        rescue
        	next
        end
      	# If come accross invalid user id then set user as admin so we dont loose attachment
      	author = User.find(users_map[attachment.created_by]) rescue User.find(1)
      	issue = Issue.find(issues_map[attachment.bug_id])
        
        a = Attachment.new :created_on => Time.at(attachment.created_date)
        a.container = issue
        a.filename = attachment.file_name
        a.disk_filename = issue.id.to_s + "-" + attachment.file_name
        a.filesize = attachment.file_size
        a.author = author
        a.description = attachment.description
        a.disk_directory = "phpbt_files"
        a.save
      end
      puts
      puts


      ##################################################################
      ############### UPDATE PROJECT TRACKER ASSOCIATION ###############
      ##################################################################
      puts "\e[34m" + "Updating Project Trackers" + "\e[32m"
      bar = ProgressBar.new(Project.count)
      Project.all.each do |proj|
      	bar.increment!
        proj.trackers.clear
        proj.trackers << TRACKER_BUG
        proj.trackers << TRACKER_FEATURE
        proj.trackers << TRACKER_SUPPORT
      end


      ##########################################################################
      ############### SET INACTIVE USERS STATUS BACK TO INACTIVE ###############
      ##########################################################################
      puts "\e[34m" + "Updating Inactive User Statuses" + "\e[32m"
      bar = ProgressBar.new(phpbt_inactive_users.count)			
			phpbt_inactive_users.each do |old_id, new_id|
				bar.increment!
				u = User.find(new_id)
				u.update_attributes!(:status => 3)
			end


      ##################################################################
      ############### PRINT OUT STATUS OF EACH MIGRATION ###############
      ##################################################################
      puts
      puts "\e[35m" 
      puts "User Map Size - #{users_map.size}"
      puts "Project Map Size - #{projects_map.size}"
      puts "Version Map Size #{versions_map.size}"
      puts "Issue Map Size - #{issues_map.size}"
      puts "Severities: #{Tracker.count}/#{PhpbtSeverity.count}"
      puts "Users: #{User.count}/#{PhpbtUser.count}"
      puts "Projects: #{Project.count}/#{PhpbtProject.count}"
      puts "Versions: #{Version.count}/#{PhpbtVersion.count}"
      puts "Bugs: #{Issue.count}/#{PhpbtBug.count}"
      puts "Comments: #{Journal.count}/#{PhpbtComment.count}"
      puts "CC's: #{Watcher.count}/#{PhpbtBugCC.count}"
      puts "Dependency's: #{IssueRelation.count}/#{PhpbtBugDependency.count}"
      puts "History: #{JournalDetail.count}/#{PhpbtBugHistory.count}"
      puts "Attachments: #{Attachment.count}/#{PhpbtAttachment.count}" + "\e[0m" 
    end

    def self.encoding(charset)
      @charset = charset
    end

    def self.establish_connection(params)
      constants.each do |const|
        klass = const_get(const)
        next unless klass.respond_to? 'establish_connection'
        klass.establish_connection params
      end
    end

    def self.encode(text)
      if RUBY_VERSION < '1.9'
        @ic ||= Iconv.new('UTF-8', @charset)
        @ic.iconv text
      else
        text.to_s.force_encoding(@charset).encode('UTF-8')
      end
    end
    
    # Extend logger to rake
    def self.logger
      @logger = Logger.new('log/production.log')
      @logger.level = Logger::DEBUG
      @logger
    end

  end

  puts
  if Redmine::DefaultData::Loader.no_data?
    puts "\e[31m"
    puts "Redmine configuration need to be loaded before importing data."
    puts "Please, run this first:"
    puts
    puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
    puts "\e[0m" 
    exit
  end

  puts "\e[33m" + "WARNING: Your Redmine data will be deleted during this process."
  print "Are you sure you want to continue ? [y/N] " + "\e[0m" 
  STDOUT.flush
  break unless STDIN.gets.match(/^y$/i)

  # Default phpbt database settings
  db_params = {:adapter => 'mysql2',
               :database => 'bugtracker',
               :host => 'localhost',
               :port => '3306',
               :username => 'root',
               :password => '' }

  puts
  puts "\e[35m" + "Please enter settings for your phpBugTracker database"
  [:adapter, :host, :port, :database, :username, :password].each do |param|
    print "\e[35m" + "#{param} [#{db_params[param]}]: " + "\e[0m" 
    value = STDIN.gets.chomp!
    db_params[param] = value unless value.blank?
  end
  #encoding = 'UTF-8'
  #PhpbtMigrate.encoding encoding

  while true
    print "\e[35m" + "encoding [UTF-8]: " + "\e[0m"
    STDOUT.flush
    encoding = STDIN.gets.chomp!
    encoding = 'UTF-8' if encoding.blank?
    break if PhpbtMigrate.encoding encoding
    puts "\e[31m" + "Invalid encoding!" + "\e[0m"
  end
  puts

  # Make sure bugs can refer bugs in other projects
  Setting.cross_project_issue_relations = 1 if Setting.respond_to? 'cross_project_issue_relations'

  old_notified_events = Setting.notified_events
  old_password_min_length = Setting.password_min_length
  begin
    # Turn off email notifications temporarily
    Setting.notified_events = []
    Setting.password_min_length = 1
    # Run the migration
    PhpbtMigrate.establish_connection db_params
    PhpbtMigrate.migrate
  ensure
    # Restore previous settings
    Setting.notified_events = old_notified_events
    Setting.password_min_length = old_password_min_length
  end

end
end
