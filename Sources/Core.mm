#import "Core.h"

NSString *MallardURL(NSString *input) {
    NSString *value = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length) return @"";
    NSURLComponents *components = [NSURLComponents componentsWithString:value];
    NSString *scheme = components.scheme.lowercaseString;
    if ([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) return components.URL.absoluteString ?: @"";
    BOOL noSpaces = [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound;
    if (noSpaces && ([value containsString:@"."] || [value hasPrefix:@"localhost"] || [value hasPrefix:@"[::1]"])) {
        NSString *prefix = ([value hasPrefix:@"localhost"] || [value hasPrefix:@"127.0.0.1"] || [value hasPrefix:@"[::1]"]) ? @"http://" : @"https://";
        NSURLComponents *host = [NSURLComponents componentsWithString:[prefix stringByAppendingString:value]];
        if (host.host.length && !host.user.length && !host.password.length) return host.URL.absoluteString ?: @"";
    }
    NSURLComponents *search = [NSURLComponents componentsWithString:@"https://search.brave.com/search"];
    search.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:value]];
    return search.URL.absoluteString;
}

NSString *MallardOrigin(NSString *url) {
    NSURLComponents *c = [NSURLComponents componentsWithString:url];
    NSString *scheme = c.scheme.lowercaseString;
    if (!([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) || !c.host.length || c.user.length || c.password.length) return nil;
    NSString *host = c.host.lowercaseString;
    if ([host containsString:@":"] && ![host hasPrefix:@"["]) host = [NSString stringWithFormat:@"[%@]",host];
    BOOL standard = !c.port || ([scheme isEqual:@"https"] && c.port.intValue == 443) || ([scheme isEqual:@"http"] && c.port.intValue == 80);
    return [NSString stringWithFormat:@"%@://%@%@",scheme,host,standard ? @"" : [NSString stringWithFormat:@":%@",c.port]];
}

static NSArray *CSVError(NSError **error, NSString *description) {
    if(error) *error = [NSError errorWithDomain:@"MallardCSV" code:1 userInfo:@{NSLocalizedDescriptionKey:description}];
    return nil;
}

NSArray<NSDictionary *> *MallardParsePasswordCSV(NSString *text, NSError **error) {
    if ([text hasPrefix:@"\uFEFF"]) text = [text substringFromIndex:1];
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    NSMutableArray<NSString *> *row = [NSMutableArray array];
    NSMutableString *field = [NSMutableString string];
    BOOL quoted = NO, afterQuote = NO;
    for (NSUInteger i=0; i<text.length; ++i) {
        unichar c = [text characterAtIndex:i];
        if (quoted) {
            if (c == '"') {
                if (i+1<text.length && [text characterAtIndex:i+1]=='"') { [field appendString:@"\""]; ++i; }
                else { quoted=NO; afterQuote=YES; }
            } else [field appendFormat:@"%C", c];
        } else if (c=='"' && field.length==0 && !afterQuote) quoted=YES;
        else if(c==',' || c=='\n' || c=='\r') {
            [row addObject:[field copy]]; [field setString:@""]; afterQuote=NO;
            if(c!=',') {
                if (row.count>1 || [row[0] length]) [rows addObject:[row copy]];
                [row removeAllObjects];
                if(c=='\r' && i+1<text.length && [text characterAtIndex:i+1]=='\n') ++i;
            }
        } else {
            if(afterQuote || c=='"') return CSVError(error,@"Invalid quoted field in the password file.");
            [field appendFormat:@"%C",c];
        }
    }
    if(quoted) return CSVError(error,@"An unfinished quoted field was found in the password file.");
    if(field.length || row.count || afterQuote) { [row addObject:field]; [rows addObject:row]; }
    if(!rows.count) return CSVError(error,@"The selected file is empty.");
    NSArray *header = [rows[0] valueForKey:@"lowercaseString"];
    NSUInteger url=[header indexOfObject:@"url"], username=[header indexOfObject:@"username"], password=[header indexOfObject:@"password"];
    if(url==NSNotFound || username==NSNotFound || password==NSNotFound) return CSVError(error,@"Use a Chrome password export with url, username, and password columns.");
    NSMutableArray *records=[NSMutableArray array];
    for(NSUInteger i=1;i<rows.count;i++) {
        NSArray *r=rows[i];
        if(r.count!=header.count) return CSVError(error,[NSString stringWithFormat:@"Row %lu has a different number of columns.",(unsigned long)i+1]);
        NSString *origin=MallardOrigin(r[url]);
        if(!origin || ![r[password] length]) continue;
        [records addObject:@{@"kind":@"password",@"origin":origin,@"username":r[username],@"password":r[password]}];
    }
    return records;
}

BOOL MallardCoreTests(void) {
    int failures=0;
    auto check=[&](BOOL passed, const char *name){ if(!passed) { fprintf(stderr,"FAIL: %s\n",name); ++failures; } };
    check([MallardURL(@"hello & ducks") isEqual:@"https://search.brave.com/search?q=hello%20%26%20ducks"],"search encoding");
    check([MallardURL(@"example.com/path") isEqual:@"https://example.com/path"],"hostname navigation");
    check([MallardURL(@"localhost:8080/form") isEqual:@"http://localhost:8080/form"],"localhost navigation");
    check([MallardURL(@"javascript:alert(1)") hasPrefix:@"https://search.brave.com/"],"no executable address scheme");
    check([MallardOrigin(@"https://EXAMPLE.com:443/path") isEqual:@"https://example.com"],"origin normalization");
    check(![MallardOrigin(@"https://login.example.com") isEqual:MallardOrigin(@"https://example.com.evil.test")],"origin boundary");
    check(MallardOrigin(@"https://name:secret@example.com")==nil,"embedded credentials rejected");
    check(MallardOrigin(@"file:///etc/hosts")==nil && MallardOrigin(@"data:text/html,test")==nil,"non-web origins rejected");
    NSError *error=nil;
    NSArray *records=MallardParsePasswordCSV(@"name,url,username,password\r\nTest,https://example.test/login,\"a,b\",\"synthetic\"\"pass\nword\"\r\n",&error);
    check(records.count==1 && [records[0][@"password"] isEqual:@"synthetic\"pass\nword"],"CSV quoted comma, quote, newline");
    check(MallardParsePasswordCSV(@"url,username,password\nhttps://example.test,x,\"unfinished",&error)==nil,"malformed CSV rejected");
    check(MallardParsePasswordCSV(@"url,username,password\nhttps://example.test,x,test,extra",&error)==nil,"ragged CSV rejected");
    check(MallardParsePasswordCSV(@"\uFEFFurl,username,password\nhttps://example.test,x,test",&error).count==1,"CSV BOM");
    printf("Core checks: %s\n",failures?"FAILED":"12 passed");
    return failures==0;
}
