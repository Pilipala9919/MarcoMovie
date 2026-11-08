"""Upstream native API checks; no replacement XML parser or remote source URLs."""
from io import BytesIO
import sys
from lxml import etree, html, objectify


class OwnerElement(etree.ElementBase):
    pass


def exercise_details(owner, rounds):
    checks = 0
    outcomes = {}

    def checked(name, condition):
        nonlocal checks
        assert condition, name
        checks += 1
        outcomes[name] = outcomes.get(name, 0) + 1

    namespace = etree.FunctionNamespace('urn:marco:lxml-owner')
    namespace['identity'] = lambda context: owner
    parser = etree.XMLParser()
    parser.set_element_class_lookup(etree.ElementDefaultClassLookup(element=OwnerElement))
    etree.set_default_parser(parser)
    for _ in range(rounds):
        root = etree.fromstring('<catalog><item year="2026">电影</item><item>二</item></catalog>')
        checked('owner_element_class', isinstance(root, OwnerElement))
        checked('xpath_unicode', root.xpath('string(item[@year="2026"])') == '电影')
        checked('xpath_count', root.xpath('count(item)') == 2.0)
        checked('xpath_owner_callback', root.xpath('owner:identity()', namespaces={'owner': 'urn:marco:lxml-owner'}) == owner)
        checked('xml_serialization', etree.tostring(root, encoding='unicode').startswith('<catalog>'))
        document = html.fromstring('<html><body><a href="/video">播放</a></body></html>')
        checked('html_xpath', document.xpath('//a/@href') == ['/video'])
        checked('html_text', document.text_content() == '播放')
        data = objectify.fromstring(b'<root><number>42</number><flag>true</flag></root>')
        checked('objectify_values', data.number.pyval == 42 and data.flag.pyval is True)
        events = list(etree.iterparse(BytesIO(b'<root><item>one</item><item>two</item></root>'), tag='item'))
        checked('iterparse', [element.text for _, element in events] == ['one', 'two'])
        try:
            etree.fromstring('<broken>')
            raise AssertionError('invalid XML was accepted')
        except etree.XMLSyntaxError as error:
            checked('malformed_xml_error_log', error.error_log.last_error is not None)
        checked('parse_after_error', etree.fromstring('<after-error/>').tag == 'after-error')
        stylesheet = etree.XML(b'<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:template match="/"><out><xsl:value-of select="/catalog/item[1]"/></out></xsl:template></xsl:stylesheet>')
        transformed = etree.XSLT(stylesheet)(root)
        checked('xslt_unicode', transformed.getroot().text == '电影')
        class Resolver(etree.Resolver):
            def resolve(self, url, public_id, context):
                return self.resolve_string('<!ENTITY owner "' + owner + '">', context)
        resolving = etree.XMLParser(load_dtd=True, resolve_entities=True)
        resolving.resolvers.add(Resolver())
        resolved = etree.fromstring(b'<!DOCTYPE root SYSTEM "owner.dtd"><root>&owner;</root>', resolving)
        checked('custom_resolver_owner', resolved.text == owner)
    return {
        'owner': owner, 'rounds': rounds, 'assertions': checks,
        'checks': [{'name': name, 'passed': True, 'count': count}
                   for name, count in outcomes.items()],
        'platform': sys.platform, 'runtime': sys.version,
        'lxml_version': list(etree.LXML_VERSION),
        'libxml_version': list(etree.LIBXML_VERSION),
        'libxslt_version': list(etree.LIBXSLT_VERSION),
        'modules': {module.__name__: {
            'file': module.__file__, 'origin': module.__spec__.origin,
            'loader': type(module.__loader__).__name__,
        } for module in (etree, objectify)},
    }


def exercise(owner, rounds):
    """Preserve the original host fixture's integer result."""
    return exercise_details(owner, rounds)['assertions']
