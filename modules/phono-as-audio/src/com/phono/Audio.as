package com.phono
{
    import com.phono.*;
    import com.phono.events.*;
    import com.phono.impl.*;
    
    import flash.events.*;
    import flash.media.Microphone;
    import flash.media.MicrophoneEnhancedMode;
    import flash.media.MicrophoneEnhancedOptions;
    import flash.net.NetConnection;
    import flash.net.NetStream;
    import flash.net.ObjectEncoding;
    import flash.net.Responder;
    import flash.system.Capabilities;
    import flash.system.Security;
    import flash.system.SecurityPanel;
    import flash.utils.Dictionary;
    import flash.utils.Timer;
    import flash.utils.setTimeout;
    
    import mx.controls.Alert;
    
    public class Audio extends EnhancedEventDispatcher
    {	
	private var _mic:Microphone; // Internal mic handle for permission checking
        private var _hasEC:Boolean = false; // Are we on a flash player with a working EC
	private var _boxOpen:Boolean = false;
  private var _listenOnly:Boolean = false;
	private var _ncDict:Dictionary = new Dictionary(); // rtmpUri -> NC
	private var _ncRefCount:Dictionary = new Dictionary();
	private var _waitQs:Dictionary = new Dictionary(); // rtmpUri -> Array of functions to call
	private var _cirrusNc:NetConnection;
	private var _cirrusUri:String;
        private var _shares:Dictionary = new Dictionary(); // streamName -> Share
        private var _version:String = "0.0";
	
	public function Audio()
	{	
            // Detect version
            var version:Number = Number(Capabilities.version.split(" ")[1].split(",")[0] + "." 
                                        + Capabilities.version.split(" ")[1].split(",")[1]);
                        
            if (version > 10.3)
            {
                try {
	            _mic = Microphone.getEnhancedMicrophone();
                    var enhancedOptions:MicrophoneEnhancedOptions = new MicrophoneEnhancedOptions();
                    enhancedOptions.autoGain = false;
                    _mic.enhancedOptions = enhancedOptions;
		    _hasEC = true;
                } 
                catch(error:Error) 
                {
                    _mic = Microphone.getMicrophone();
	        }
            }
            else
            {
                _mic = Microphone.getMicrophone();
            }
        
            if (_mic)
            {
                _mic.addEventListener(StatusEvent.STATUS, onMicStatus);	
            }
            else 
            {
                dispatchEvent(new MediaEvent(MediaEvent.ERROR,null,
                                             "No microphone available."));
            }
            trace("Flash Audio() complete");
	}		
	
	// --- Public API
	
	public function get transport():String
	{
	    return "http://voxeo.com/gordon/transports/rtmp";	
	}
	
	public function get description():String
	{
	    return "http://voxeo.com/gordon/apps/rtmp";
	}

        public function doCirrusConnect(url:String):Boolean
        {
            // Connect to the given network connection url			
            var nc:NetConnection = getNetConnection(url);
	    _cirrusNc = nc;
	    _cirrusUri = url;
	    return nc.connected;
        }

        public function doCirrusDisconnect(url:String):Boolean
        {
            return releaseNetConnection(url);
        }

        public function setVersion(version:String):void
        {
            _version = version;
        }
        
        // Modified by manvuong
        // Custom code.
        public function setListenOnly(listenOnly:Boolean):void
        {
            _listenOnly = listenOnly;
        }
        
        // Modified by manvuong
        // Custom code.
        public function get listenOnly():Boolean
        {
            return _listenOnly;
        }
        
        public function nearID(url:String):String
        {
            var nc:NetConnection = getNetConnection(url);
	    var nearID:String;
	    try {
		nearID = nc.nearID;
	    } catch (e:Error) {
		nearID = "";
	    }
            // To satisfy refcounting, we are done with it now.
            releaseNetConnection(url);
            return nearID;
        }
	
	public function get codecs():Array
	{
	    var cds:Array = new Array();
	    cds.push(new Codec("97", "SPEEX", "8000"));
	    cds.push(new Codec("97", "SPEEX", "16000"));
	    return cds;
	}
	
	public function play(url:String, autoStart:Boolean, peerID:String=NetStream.CONNECT_TO_FMS, video:Boolean=false):Player
	{
	    var player:Player = null
	    var protocolName:String = getProtocolName(url);
	    if (protocolName.toLowerCase() == "rtmp"
                || protocolName.toLowerCase() == "rtmfp"
                || protocolName.toLowerCase() == "rtmpt") {
		var streamName:String;
		var rtmpUri:String;
		
		var nc:NetConnection;
		if (peerID == NetStream.CONNECT_TO_FMS) {
		    streamName = getStreamName(url);	
		    rtmpUri = getRtmpUri(url);
		    nc = getNetConnection(rtmpUri);			
		}
		else {
		    nc = _cirrusNc;
		    streamName = nc.nearID;	
		    rtmpUri = _cirrusUri;
		}
		
		var queue:Array = _waitQs[rtmpUri]
		player = new RtmpPlayer(_hasEC, queue, nc, streamName, url, peerID, function():void {
                    if (peerID == NetStream.CONNECT_TO_FMS) {
                        releaseNetConnection(rtmpUri);
                    }
                });
	    } else if (protocolName.toLowerCase() == "http" || protocolName.toLowerCase() == "https") {
		player = new HttpPlayer(url);
	    }
	    if (autoStart) player.start();
	    return player;
	}
	
	public function share(url:String, autoStart:Boolean, codecId:String="97", codecName:String="SPEEX", codecRate:String="16000", suppress:Boolean=true, peerID:String="", video:Boolean=false, reliable:Boolean=false):Share
	{
	    // Force an open request for microphone permisson if we don't already have it - 
	    // Flash will automatically open the box, so we need to be ready
	    setTimeout(function():void {
    // Modified by manvuong
		if (!_listenOnly && _mic && _mic.muted) {
		    showPermissionBox();
		}
	    },10);
	    
	    var codec:Codec = new Codec(codecId, codecName, codecRate);		
	    
	    var protocolName:String = getProtocolName(url);
	    if (protocolName.toLowerCase() == "rtmp" || protocolName.toLowerCase() == "rtmfp"
                || protocolName.toLowerCase() == "rtmpt") {
		var nc:NetConnection;
		var streamName:String;
		var rtmpUri:String;
		var direct:Boolean;
		if (peerID == "") {
		    direct = false;
		    rtmpUri = getRtmpUri(url);
		    nc = getNetConnection(rtmpUri);
		    streamName = getStreamName(url);	
		}
		else {
		    direct = true;
		    nc = _cirrusNc;
		    rtmpUri = _cirrusUri;
		    streamName = peerID;
		}
		
		var queue:Array = _waitQs[rtmpUri]
		var share:Share = new RtmpShare(_hasEC, queue, nc, streamName, codec, url, _mic, suppress, direct, reliable, function():void {
                    if (!direct) {
                        releaseNetConnection(rtmpUri);
                    }
                });
		if (autoStart) share.start();
                _shares[streamName] = share;
		return share;
	    } else return null;
	}
	
	public function get hasPermission():Boolean
	{
	    if (_mic) {
		return !_mic.muted;
	    }
	    return false;
	}
	
	public function showPermissionBox():void
	{
	    var audio:Audio = this;
	    if (!_boxOpen) {
		_boxOpen = true;	
		setTimeout(function():void {					
		    var count:Number = 0;
		    
		    dispatchEvent(new MediaEvent(MediaEvent.OPEN, audio));
		    var alert:Alert = Alert.show('', "-", Alert.OK, null, function(e:Event):void {
			dispatchEvent(new MediaEvent(MediaEvent.CLOSE, audio));
			_boxOpen = false;
		    });

                    alert.alpha = 0;

		    var listener:Function = function(event:flash.events.Event):void {
			if(count == 0) {
			    Security.showSettings(SecurityPanel.PRIVACY);
			    count = count +1;
			}
			else if(count == 1) {
                            Security.showSettings(SecurityPanel.PRIVACY);
			    count = count +1;
			}
			else {
			    alert.removeEventListener(flash.events.Event.RENDER, listener);
			    alert.visible = false;
			    dispatchEvent(new MediaEvent(MediaEvent.CLOSE, audio));
			    _boxOpen = false;
			}
		    };
		    
		    alert.addEventListener(flash.events.Event.RENDER, listener);

		}, 100);		
	    }
	}	

	// --- Internal functions
	
	private function onMicStatus(event:StatusEvent):void 
	{
	    if ((event.code == "Microphone.Unmuted" || event.code == "Microphone.Muted") && _boxOpen == false) {
                dispatchEvent( new MediaEvent(MediaEvent.CLOSE) );
	    }
	}
	
	// Parse the uri, lookup or create a network connection and return it
	private function getNetConnection(uri:String):NetConnection
	{
	    var nc:NetConnection;
	    var rtmpUri:String = uri;
            // See if we already have it open
	    if (_ncDict[rtmpUri] != null) {
                nc = _ncDict[rtmpUri];
                _ncRefCount[rtmpUri] = _ncRefCount[rtmpUri] + 1;
            } else {
		nc = new NetConnection();
		nc.client = this;
		nc.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onNCSecurityError);    
		nc.addEventListener(AsyncErrorEvent.ASYNC_ERROR, onNCAsyncError);
		nc.addEventListener(NetStatusEvent.NET_STATUS, 
				    function(event:NetStatusEvent):void
				    {
					trace("NetStatusEvent:" + event.info.code);
					switch (event.info.code)
					{
					case "NetConnection.Connect.Success":
					    // Now we can play and publish                	
					    for each (var op:Object in _waitQs[rtmpUri]) {
						op();
					    }	
					    delete _waitQs[rtmpUri];
                                            dispatchEvent(new MediaEvent(MediaEvent.CONNECTED,null,
                                                                         "Flash NetConnection Connected"));
					    break;
                                        case "NetConnection.Connect.Closed":
                                            dispatchEvent(new MediaEvent(MediaEvent.ERROR,null,
                                                                         "Flash NetConnection Closed (network problem?)"));
                                            break;
                                        case "NetConnection.Connect.Failed":
                                            dispatchEvent(new MediaEvent(MediaEvent.ERROR,null,
                                                                         "Flash NetConnection Failed (firewall problem?)"));
                                            break;
                                        case "NetConnection.Connect.Rejected":
                                            dispatchEvent(new MediaEvent(MediaEvent.ERROR,null,
                                                                         "Flash NetConnection Rejected (server error?)"));
                                            break;
                                        case "NetStream.Connect.Failed":
                                            dispatchEvent(new MediaEvent(MediaEvent.ERROR,null,
                                                                         "Flash NetStream Connect Failed (firewall problem?)"));
                                            break;
                                        case "NetStream.Connect.Rjected":
                                            dispatchEvent(new MediaEvent(MediaEvent.ERROR,null,
                                                                         "Flash NetStream Connect Rejected (server error?)"));
                                            break;
					}
				    });
		nc.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onNCSecurityError);    
		nc.addEventListener(AsyncErrorEvent.ASYNC_ERROR, onNCAsyncError);
		nc.connect(rtmpUri, _version);
		// Allocate storage
		_ncDict[rtmpUri] = nc;
                _ncRefCount[rtmpUri] = 1;
		_waitQs[rtmpUri] = new Array();
	    }
	    return nc;
	}


        // Close the NetConnection, returns true if ref count 0 and actually closed
        private function releaseNetConnection(uri:String):Boolean
        {
            _ncRefCount[uri] = _ncRefCount[uri] - 1;
            if (_ncRefCount[uri] == 0) {
                var nc:NetConnection = _ncDict[uri];
                nc.close();
                delete _ncDict[uri];
                delete _ncRefCount[uri];
                return true;
            }
            return false;
        }
	
	// Parse the uri and return the rtmpUri
	private function getRtmpUri(uri:String):String
	{
	    var rtmpUri:String = "";
	    return uri.substr(0,uri.lastIndexOf("/"));
	}
	
	// Parse the uri and return the stream name
	private function getStreamName(uri:String):String
	{
	    var streamName:String = "";
	    return uri.substr(uri.lastIndexOf("/")+1);
	}
	
	// Parse the uri and return the protocol name
	private function getProtocolName(uri:String):String
	{
	    var protocolName:String = "";
	    var split:Array = uri.split(":");	
	    protocolName = split[0];
	    return protocolName;
	}
	
	internal function onNCSecurityError(event:SecurityErrorEvent):void
	{
	    dispatchEvent( new MediaEvent(MediaEvent.ERROR, null, "Flash Security Error (server error?)") );
	}
	
	internal function onNCAsyncError(event:AsyncErrorEvent):void 
	{
	    dispatchEvent( new MediaEvent(MediaEvent.ERROR, null, "Flash Async Error (server error?)") );
	}

	// --- External functions
	
	public function onBWDone():void
	{
	    // Blank template for callback from rtmp relay
	}			

        public function pandaReady(streamName:String):void
        {
            // This needs to be relayed up to the Share
            var share:RtmpShare = _shares[streamName];
            share.mediaReady();
        }
    }
}

