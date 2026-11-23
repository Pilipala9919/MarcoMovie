"""App-owned Python Spider helpers, independent of the Android Java bridge."""
import json
import re

import requests


class Spider:
    def __init__(self):
        self.extend = ""

    def init(self, extend=""):
        self.extend = extend

    @staticmethod
    def regStr(reg, src, group=1):
        found = re.search(reg, src)
        return "" if found is None else found.group(group)

    @staticmethod
    def removeHtmlTags(src):
        return re.sub(r"<.*?>", "", src)

    @staticmethod
    def cleanText(src):
        # Match the legacy Spider helper's four emoji ranges. Preserve other
        # Unicode text rather than stripping all non-BMP characters.
        return re.sub("[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF"
                      "\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF]", "", src)

    @staticmethod
    def html(content):
        # Keep parser loading lazy: sources that do not need HTML should not
        # pay for an lxml import at startup.
        from lxml import etree
        return etree.HTML(content)

    @staticmethod
    def str2json(value):
        return json.loads(value)

    @staticmethod
    def json2str(value):
        return json.dumps(value, ensure_ascii=False)

    @staticmethod
    def log(message):
        print(json.dumps(message, ensure_ascii=False)
              if isinstance(message, (dict, list)) else str(message))

    @staticmethod
    def page(items, pg, limit, total=None):
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
            raise ValueError("page requires a positive limit")
        page = max(1, int(pg))
        if total is None:
            total = len(items)
            start = (page - 1) * limit
            items = items[start:start + limit]
        if isinstance(total, bool) or not isinstance(total, int) or total < 0:
            raise ValueError("page requires a nonnegative total")
        pages = max(1, (total + limit - 1) // limit)
        return dict(list=items, page=page, pagecount=pages, limit=limit, total=total)

    def fetch(self, url, **kwargs):
        return requests.get(url, **kwargs)

    def post(self, url, **kwargs):
        return requests.post(url, **kwargs)

    def getProxyUrl(self, params=None, local=True):
        return _HOST.proxy_url(params, local, legacy=True)

    def proxyUrl(self, params=None, local=True):
        return _HOST.proxy_url(params, local)

    def homeContent(self, filter):
        raise NotImplementedError("Python Spider is missing homeContent")

    def homeVideoContent(self):
        raise NotImplementedError("Python Spider is missing homeVideoContent")

    def categoryContent(self, tid, pg, filter, extend):
        raise NotImplementedError("Python Spider is missing categoryContent")

    def detailContent(self, ids):
        raise NotImplementedError("Python Spider is missing detailContent")

    def searchContent(self, key, quick, pg="1"):
        raise NotImplementedError("Python Spider is missing searchContent")

    def playerContent(self, flag, id, vipFlags):
        raise NotImplementedError("Python Spider is missing playerContent")

    # Do not declare localProxy/proxy: an inherited stub must not hide the other
    # real entrypoint supplied by a source.
