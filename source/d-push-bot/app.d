module d_push_bot;

import vibe.vibe;

import std.algorithm;
import std.datetime.systime;
import std.functional;
import std.stdio;
import std.uri : encodeComponent;

struct Config
{
	string pushUrl;
	string feed;
}

SysTime configDate;
Config config;
void main()
{
	config = deserializeJson!Config(parseJsonString(readFileUTF8("config.json")));
	configDate = getFileInfo("config.json").timeModified;
	setTimer(10.minutes, (&checkUpdates).toDelegate);
	runTask(&checkUpdates);
	runApplication();
}

void checkUpdates()
{
	auto configModify = getFileInfo("config.json").timeModified;
	if (configModify > configDate)
	{
		config = deserializeJson!Config(parseJsonString(readFileUTF8("config.json")));
		configDate = configModify;
	}
	runTask(&checkDubUpdates);
	runTask(&checkAnnounceFeed);
}

string requestString(string url)
{
	string ret;
	requestHTTP(url, (scope req) {  }, (scope res) {
		if (res.statusCode != 200)
			throw new Exception("HTTP request failed with code " ~ res.statusCode.to!string);
		ret = res.bodyReader.readAllUTF8;
	});
	return ret;
}

void checkAnnounceFeed()
{
	import dxml.parser;
	import dxml.parser;
	import dxml.util;

	SysTime now = Clock.currTime;
	SysTime lastUpdate = SysTime(DateTime.init, UTC());
	if (existsFile("feed-date.txt"))
		lastUpdate = SysTime.fromISOExtString(readFileUTF8("feed-date.txt").strip);
	auto xml = parseXML!simpleXML(requestString(config.feed));
	if (xml.empty)
		throw new Exception("XML suddenly stopped");
	if (xml.front.type != EntityType.elementStart || xml.front.name != "feed")
		throw new Exception("Malformed xml returned");
	while (!xml.empty && (xml.front.type != EntityType.elementStart || xml.front.name != "entry"))
	{
		xml.popFront();
		if (xml.empty)
			throw new Exception("XML suddenly stopped");
		xml = xml.skipToEntityType(EntityType.elementStart);
	}
	while (!xml.empty)
	{
		try
		{
			if (xml.empty || xml.front.type != EntityType.elementStart || xml.front.name != "entry")
				throw new Exception("Did not get entry, but got " ~ xml.front.name);
			if (xml.empty)
				throw new Exception("XML suddenly stopped");
			xml.popFront();
			if (xml.empty)
				throw new Exception("XML suddenly stopped");
			Embed[1] embed;
			while (!xml.empty && (xml.front.type != EntityType.elementEnd || xml.front.name != "entry"))
			{
				if (xml.front.type == EntityType.elementStart && xml.front.name == "title")
				{
					xml.popFront;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
					if (xml.front.type != EntityType.text)
						throw new Exception("Invalid title content");
					embed[0].title = xml.front.text.strip.decodeXML;
					xml = xml.skipToParentEndTag;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
				}
				else if (xml.front.type == EntityType.elementStart && xml.front.name == "published")
				{
					xml.popFront;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
					if (xml.front.type != EntityType.text)
						throw new Exception("Invalid published content");
					embed[0].timestamp = xml.front.text.strip;
					xml = xml.skipToParentEndTag;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
				}
				else if ((xml.front.type == EntityType.elementStart
						|| xml.front.type == EntityType.elementEmpty) && xml.front.name == "link")
				{
					auto attribs = xml.front.attributes;
					if (attribs.empty)
						throw new Exception("Empty attributes on link tag");
					if (attribs.front.name != "href")
						throw new Exception("Invalid attribute on link tag");
					embed[0].url = attribs.front.value;
				}
				else if (xml.front.type == EntityType.elementStart && xml.front.name == "content")
				{
					xml.popFront;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
					if (xml.front.type != EntityType.text)
						throw new Exception("Invalid content content");
					string text = xml.front.text.strip.decodeXML.parseXML!simpleXML.filter!(
							a => a.type == EntityType.text).map!(a => a.text.decodeXML).join();
					if (text.length > 1024)
						text = text[0 .. 1021] ~ "...";
					embed[0].description = text;
					xml = xml.skipToParentEndTag;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
				}
				else if (xml.front.type == EntityType.elementStart && xml.front.name == "author")
				{
					xml.popFront;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
					if (xml.front.type != EntityType.elementStart)
					{
						xml = xml.skipToEntityType(EntityType.elementStart);
						if (xml.empty)
							throw new Exception("XML suddenly stopped");
					}
					if (xml.front.name != "name")
						throw new Exception("Invalid author content");
					xml.popFront;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
					if (xml.front.type != EntityType.text)
						throw new Exception("Invalid author text");
					embed[0].author.name = xml.front.text.strip.decodeXML;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
					xml = xml.skipToParentEndTag;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
					xml = xml.skipToParentEndTag;
					if (xml.empty)
						throw new Exception("XML suddenly stopped");
				}
				else if (xml.front.type == EntityType.elementStart)
					xml = xml.skipContents();
				if (xml.empty)
					throw new Exception("XML suddenly stopped");
				xml.popFront();
				if (xml.empty)
					throw new Exception("XML suddenly stopped");
			}
			if (embed[0] != Embed.init && SysTime.fromISOExtString(embed[0].timestamp) > lastUpdate)
			{
				sleep(2.seconds);
				sendEmbeds(embed[], "D Announce");
			}
			if (xml.empty)
				throw new Exception("XML suddenly stopped");
			if (xml.front.type == EntityType.elementEnd && xml.front.name == "entry")
			{
				xml.popFront();
				if (xml.empty)
					throw new Exception("XML suddenly stopped");
			}
		}
		catch (Exception e)
		{
			logError("Failed to update post in newsgroup: %s", e);
			if (!xml.empty)
			{
				if (xml.front.type == EntityType.elementStart)
					xml = xml.skipContents();
				else
					xml.popFront;
			}
		}
	}
	writeFileUTF8(NativePath("feed-date.txt"), now.toISOExtString);
}

void checkDubUpdates()
{
	string[] currentPackages = deserializeJson!(string[])(
			parseJsonString(requestString("https://code.dlang.org/packages/index.json")));
	scope (exit)
		currentPackages.destroy;
	{
		auto lastPackages = File("packages.txt");
		foreach (pkg; currentPackages)
		{
			if (!lastPackages.byLine.canFind(pkg))
			{
				auto info = parseJsonString(requestString(
						"https://code.dlang.org/packages/" ~ pkg.encodeComponent ~ ".json"));
				string gitUrl;
				auto repo = info["repository"];
				switch (repo["kind"].get!string)
				{
				case "github":
					gitUrl = "https://github.com/";
					break;
				case "gitlab":
					gitUrl = "https://gitlab.com/";
					break;
				case "bitbucket":
					gitUrl = "https://bitbucket.org/";
					break;
				default:
					break;
				}
				if (gitUrl.length)
					gitUrl ~= repo["owner"].get!string ~ "/" ~ repo["project"].get!string;
				sendMessage("A new dub packages has just been released:\nhttps://code.dlang.org/packages/"
						~ pkg.encodeComponent ~ "\n" ~ gitUrl, "DUB Package Releases");
				sleep(2.seconds);
			}
		}
	}
	{
		auto write = File("packages.txt", "w");
		foreach (pkg; currentPackages)
			write.writeln(pkg);
	}
}

void sendMessage(string msg, string username = null)
{
	requestHTTP(config.pushUrl, (scope req) {
		req.method = HTTPMethod.POST;
		Json obj = Json.emptyObject;
		if (username.length)
			obj["username"] = Json(username);
		obj["content"] = msg;
		req.writeJsonBody(obj);
	}, (scope res) {  });
}

struct Embed
{
	struct Author
	{
		string name;
	}

	string title;
	string type = "rich";
	string description;
	string url;
	string timestamp;
	int color = 0xB03931;
	Author author;
}

void sendEmbeds(Embed[] msg, string username = null)
{
	requestHTTP(config.pushUrl, (scope req) {
		req.method = HTTPMethod.POST;
		Json obj = Json.emptyObject;
		if (username.length)
			obj["username"] = Json(username);
		obj["embeds"] = serializeToJson(msg);
		req.writeJsonBody(obj);
	}, (scope res) {  });
}
