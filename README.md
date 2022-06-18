## SourceMod Smart FastDownloads allows server owners to define multiple "download nodes" via a simple config file. 

**As of right now, this can only run on Team Fortress 2 Windows and Linux servers, as that's the only Source game I make projects for.Theoretically, this can run on any Source-based game.**

##### When a client connects, this plugin calculates the distance between them and each of the specified download nodes and routes the client to the closest node available. This can elminate potential download speed bottlenecks when too many clients are trying to access a single webserver at the same time or when a webserver is physically too far away from major player groups.

**Dependencies**

* [SxGeo Extension](https://forums.alliedmods.net/showthread.php?t=311377) - this provides the geodatabase **OR** [GeoIP2 Extension that ships with newest SourceMod 1.11 dev builds](https://www.sourcemod.net/downloads.php?branch=dev)
* Own gamedata, which is easy to find.

**Points of failure/Limitations**

* Client's IP address may not be in the SypexGeo/GeoIP2 database. If such event occurs, the plugin will fall back to the original fastdownload value, defined by **sv_downloadurl**.
* Since this plugin relies solely on internal database info, distance/location calculation may be rather inaccurate.
* _Undiscovered...?_

**ConVars**
* **sfd_lookup** - Defines which database to use. 0 - SypexGeo, 1 - GeoIP2 with SourceMod 1.11.
* **sfd_debug**  - Certain debug information will be written to the **fastdl_debug.log** file located in the **sourcemod** folder.

**Usage**
* Upload the files to their respective folders.
* Edit the configuration file under _configs/fastdlmanager.cfg_.
* Start the server/load the plugin. Please note that the main configuration file must be edited BEFORE the plugin starts and that any non-KeyValue information will be lost.
