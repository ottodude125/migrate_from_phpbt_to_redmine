
# Migrate phpBugTracker database to Redmine 
========================


### INTRODUCTION

This rake task was written to migrate a phpBugTracker 1.0.5 mysql database
to a Redmine 2.5 mysql database. It has not been tested with any other configuration
and therefore I have no idea if it will work or not. I am making this available
as an example of how I migrated my database. The exact configuration in this
script may not meet your exact needs and therefore it is highly recommended that
you read through the entire script and updated it accordingly. Some items I stole
from the migrate_from_mantis.rake script that was included with the Redmine 2.5
distribution.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.


### NOTES AND REQUIREMENTS 

1. My phpbt db consisted of ~70,000 records. The import would take approximately
30 minutes to complete. To provide some informative feedback during this process 
I implemented a progress bar with each table imported. This progress bar is one of 
include statements. To find more information on the bar you can go to
https://github.com/paul/progress_bar. Before you run this scrip you need to either 
comment out those lines that set up the bar or you need to install the gem. 
As of Redmine 2.5 you can add private gems to Gemfile.local and then rebundle.

2. If rake is unable to import a user it will alert you of what users it was unable
to import.

3. If it finds duplicate versions on the same project it will merge them 
rather than import all version

4. When importing issues if the author, or assigned to cannot be found
the script will automatically assign the admin user. 

5. This script assumes you have installed the "Banner" plugin. It will assign
this module to all projects. If this is not true then update that line in the
migrate projects section. https://github.com/akiko-pusu/redmine_banner

6. When importing comments if issue cannot be found it will skip user. Also
if created_by cannot be found it assigns Admin user to comment so it is not lost

7. When importing cc's it skips the cc if it cannot find the issue or the user.
No sense importing a cc if we have no idea where or who

8. When importing dependency it skips it if it cannot find the bug or the bug it
depends on

9. When importing bug history if the issue cannot be found the history is skipped

10. Imported attachments have the original bug id and a "-" appended to front of
filename. I am not sure if this is normal but all my phpbt attachment files used that
format for filenames so I programmed it like that so files could be found. 
Additionally all phpbt files were pulled from their folders and placed in a single
folder called phpbt_files in the redmine files folder. I did not have any duplicate
filenames when doing this. You may not be so lucky and therefore may need to alter
the way this section is imported. 

11. We had configured our phpbt to have 10 Severities(Trackers) - three of them matching redmine
We wanted to maintain this configuration in Redmine but we only wanted the three original
redmine trackers to be active for all projects. For this reason to run the import
all trackers are initially assigned to all projects. Once we have completed importing
all the data we update all projects to use only the feature, bug, and support trackers

12. I was having a problem with the rake task complaining that I was trying to assign an
inactive user to an issue. To work around this all users when first imported are set to active
I then, once all migrations are completed, update all users to their correct status. 

13. Script assumes that you are using LDAP and sets the auth_source_id to 1. If this is not
true you will need to update accordingly


### PROCESS I FOLLOWED TO SETUP REDMINE 
I was installing a completely brand new Redmine instance. The only data
involved was from my phpbt database. This process WILL DELETE any data
that is currently in your Redmine database.

1. Comment out errors.add line in app/models/watcher.rb validate_user method
2. Comment out errors.add circular in app/models/issue_relation.rb validate_issue_relation method
3. Comment out errors.add fixed version id inclusion line in app/models/issue.rb validate_issue if fixed_issue method
4. Run the following to create and setup the database/app
  
  ```ruby
  RAILS_ENV=production rake db:drop; 
  RAILS_ENV=production rake db:create; 
  rake generate_secret_token; 
  RAILS_ENV=production rake db:migrate; 
  RAILS_ENV=production rake redmine:plugins:migrate; 
  RAILS_ENV=production rake redmine:load_default_data;
  ```

5. Log in as admin, go to administration section and:
  * Configure all tabs in settings section
  * Set up LDAP that all users will use

6. Pull the attachment files from phpbt to redmine
  * Create folder "phpbt_files" in redmine/files/

  ``` bash
  # List number of files in phpbt/attachments directory
  find ./ -type f | wc -l 
  # Copy all files from phpbt/attachments to redmine/files/phpbt_files
  find ./ -type f -exec cp -- '{}' "../../redmine/files/phpbt_files" \; 
  ```

7. Run the following to run this script
  ``` ruby
  RAILS_ENV=production rake redmine:migrate_from_phpbt;
  ```

8. Uncomment out lines in #1, #2, and #3
9. Go back to administration section and update settings and users, groups, permissions, and projects as needed.




