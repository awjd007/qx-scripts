(function(){var u="";try{if(typeof $request!=="undefined"&&$request&&$request.url)u=String($request.url);}catch(e){}
var hr=false;try{hr=(typeof $response!=="undefined"&&!!$response);}catch(e){}
try{if(typeof $notify!=="undefined")$notify("LK信标[CDN]已执行","fastly.jsdelivr.net","","");}catch(e){}
try{$done({});}catch(e){}})();
