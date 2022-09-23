Disabling automatic Thunderbird updates - mainly to get rid of annoying popups that were bothering users.
The only way to accomplish it right now is to create a policy file in TB directory that blocks all updates. The script was written to deploy this solution to all users via our patching platform. The code works as follows:
* Creates required 'distribution' folder in Tb directory
* Creates a text file and writes JavaScript that disables update to it
* Changes file extension to .json to make it readable by Thunderbird
* Kills Thunderbird (if it's running)
* Starts Thunderbird again to make changes work