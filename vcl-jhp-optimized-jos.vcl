vcl 4.0;
import std;
# THIS IS THE OPTIMIZED VCL BY JOS JONKEREN TO CACHE MORE OR LESS ALL
# The minimal Varnish version is 4.0
# For SSL offloading, pass the following header in your proxy server or load balancer: 'X-Forwarded-Proto: https'
backend default {
    .host = "localhost";
    .port = "8080";
    .first_byte_timeout = 600s;
}
acl purge {
    "localhost";
}
sub vcl_recv {
    if (req.method == "PURGE") {
        if (client.ip !~ purge) {
            return (synth(405, "Method not allowed"));
        }
        # To use the X-Pool header for purging varnish during automated deployments, make sure the X-Pool header
        # has been added to the response in your backend server config. This is used, for example, by the
        # capistrano-magento2 gem for purging old content from varnish during it's deploy routine.
        if (!req.http.X-Magento-Tags-Pattern && !req.http.X-Pool) {
            return (synth(400, "X-Magento-Tags-Pattern or X-Pool header required"));
        }
        if (req.http.X-Magento-Tags-Pattern) {
          ban("obj.http.X-Magento-Tags ~ " + req.http.X-Magento-Tags-Pattern);
        }
        if (req.http.X-Pool) {
          ban("obj.http.X-Pool ~ " + req.http.X-Pool);
        }
        return (synth(200, "Purged"));
    }
    if (req.method != "GET" &&
        req.method != "HEAD" &&
        req.method != "PUT" &&
        req.method != "POST" &&
        req.method != "TRACE" &&
        req.method != "OPTIONS" &&
        req.method != "DELETE") {
          /* Non-RFC2616 or CONNECT which is weird. */
          return (pipe);
    }
    # We only deal with GET and HEAD by default
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }
    # Bypass shopping cart, checkout and search requests
    if (req.url ~ "/checkout" || req.url ~ "/catalogsearch" || req.url ~ "/robots" || req.url ~ "/sitemap") {
        return (pass);
    }
    # Bypass health check requests
    if (req.url ~ "/pub/health_check.php") {
        return (pass);
    }
    # Set initial grace period usage status
    set req.http.grace = "none";
    # normalize url in case of leading HTTP scheme and domain
    set req.url = regsub(req.url, "^http[s]?://", "");
    # collect all cookies
    std.collect(req.http.Cookie);
    # Compression filter. See https://www.varnish-cache.org/trac/wiki/FAQ/Compression
    if (req.http.Accept-Encoding) {
        if (req.url ~ "\.(jpg|jpeg|png|gif|gz|tgz|bz2|tbz|mp3|ogg|swf|flv)$") {
            # No point in compressing these
            unset req.http.Accept-Encoding;
        } elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate" && req.http.user-agent !~ "MSIE") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            # unknown algorithm
            unset req.http.Accept-Encoding;
        }
    }
    # Remove all marketing get parameters to minimize the cache objects
    if (req.url ~ "(\?|&)(gclid|cx|ie|cof|siteurl|zanpid|origin|fbclid|mc_[a-z]+|utm_[a-z]+|_bta_[a-z]+)=") {
        set req.url = regsuball(req.url, "(gclid|cx|ie|cof|siteurl|zanpid|origin|fbclid|mc_[a-z]+|utm_[a-z]+|_bta_[a-z]+)=[-_A-z0-9+()%.]+&?", "");
        set req.url = regsub(req.url, "[?|&]+$", "");
    }
    # Static files caching
    if (req.url ~ "^/(pub/)?(media|static)/") {
        # Static files should not be cached by default
        # return (pass);
        # But if you use a few locales and don't use CDN you can enable caching static files by commenting previous line (#return (pass);) and uncommenting next 3 lines
        unset req.http.Https;
        unset req.http.X-Forwarded-Proto;
        unset req.http.Cookie;
    }
    return (hash);
}
sub vcl_hash {
    if (req.http.cookie ~ "X-Magento-Vary=") {
        hash_data(regsub(req.http.cookie, "^.*?X-Magento-Vary=([^;]+);*.*$", "\1"));
    }
    # For multi site configurations to not cache each other's content
    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }
    if (req.url ~ "/graphql") {
        call process_graphql_headers;
    }
    # To make sure http users don't see ssl warning
    if (req.http.X-Forwarded-Proto) {
        hash_data(req.http.X-Forwarded-Proto);
    }
    
}
sub process_graphql_headers {
    if (req.http.Store) {
        hash_data(req.http.Store);
    }
    if (req.http.Content-Currency) {
        hash_data(req.http.Content-Currency);
    }
}
sub vcl_backend_response {
    
	# Allow stale content, in case the backend goes down.  
    # make Varnish keep all objects for 12 hours beyond their TTL 
	set beresp.grace = 12h;
	
	# client browser and server cache  
    # Force cache: remove expires, Cache-control & Pragma header coming from the backend  
    if (beresp.http.Cache-Control ~ "(no-cache|private)" || beresp.http.Pragma ~ "no-cache") {  
         unset beresp.http.Expires;  
         unset beresp.http.Cache-Control;  
         unset beresp.http.Pragma;
	}
	
    if (beresp.http.content-type ~ "text") {
        set beresp.do_esi = true;
    }
    if (bereq.url ~ "\.js$" || beresp.http.content-type ~ "text") {
        set beresp.do_gzip = true;
    }
    if (beresp.http.X-Magento-Debug) {
        set beresp.http.X-Magento-Cache-Control = beresp.http.Cache-Control;
    }
    # cache only successfully responses and 404s
    if (beresp.status != 200 && beresp.status != 404) {
        set beresp.ttl = 0s;
        set beresp.uncacheable = true;
        return (deliver);
    } elsif (beresp.http.Cache-Control ~ "private") {
        set beresp.uncacheable = true;
        set beresp.ttl = 1m;
        return (deliver);
    }
    # validate if we need to cache it and prevent from setting cookie
    if (beresp.ttl > 0s && (bereq.method == "GET" || bereq.method == "HEAD")) {
        unset beresp.http.set-cookie;
    }
   # If page is not cacheable then bypass varnish for 2 minutes as Hit-For-Pass
   if (beresp.ttl <= 0s ||
       beresp.http.Surrogate-control ~ "no-store" ||
       (!beresp.http.Surrogate-Control &&
       beresp.http.Cache-Control ~ "no-cache|no-store") ||
       beresp.http.Vary == "*") {
       # Mark as Hit-For-Pass for the next 2 minutes
        set beresp.ttl = 120s;
        set beresp.uncacheable = true;
    }
    return (deliver);
}
sub vcl_deliver {
    if (resp.http.X-Magento-Debug) {
        if (resp.http.x-varnish ~ " ") {
            set resp.http.X-Magento-Cache-Debug = "HIT";
            set resp.http.Grace = req.http.grace;
        } else {
            set resp.http.X-Magento-Cache-Debug = "MISS";
        }
    } else {
        unset resp.http.Age;
    }
    # Commented three lines below to let browser cache non-static files.
    if (resp.http.Cache-Control !~ "private" && req.url !~ "^/(pub/)?(media|static)/") {
        #set resp.http.Pragma = "no-cache";
        #set resp.http.Expires = "-1";
        #set resp.http.Cache-Control = "no-store, no-cache, must-revalidate, max-age=0";
    }
    unset resp.http.X-Magento-Debug;
    unset resp.http.X-Magento-Tags;
    unset resp.http.X-Powered-By;
    unset resp.http.Server;
    unset resp.http.X-Varnish;
    unset resp.http.Via;
    unset resp.http.Link;
}
sub vcl_hit {
    if (obj.ttl >= 0s) {
        # Hit within TTL period
        return (deliver);
    }
    if (std.healthy(req.backend_hint)) {
        if (obj.ttl + 1800s > 0s) {
            # Hit after TTL expiration, but within grace period
            set req.http.grace = "normal (healthy server)";
            return (deliver);
        } else {
            # Hit after TTL and grace expiration
            return (fetch);
        }
    } else {
        # server is not healthy, retrieve from cache
        set req.http.grace = "unlimited (unhealthy server)";
        return (deliver);
    }
}
