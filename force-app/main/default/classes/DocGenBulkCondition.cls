/** Validates and composes the WHERE fragment for a user-mode bulk selector. */
public with sharing class DocGenBulkCondition {
    private static final Integer MAX_GROUP_DEPTH = 20;
    private static final Integer MAX_RELATIONSHIP_HOPS = 5;
    private static final Integer MAX_SEMI_JOINS = 2;
    private static final Pattern FIELD_PATH = Pattern.compile('[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)*');
    private static final Pattern NUMBER_LITERAL = Pattern.compile(
        '[+-]?(?:[0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)(?:[Ee][+-]?[0-9]+)?'
    );
    private static final Pattern DATE_LITERAL = Pattern.compile(
        '[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{1,3})?(?:[Zz]|[+-][0-9]{2}:[0-9]{2}))?'
    );
    private static final Pattern OFFSET_DATE_LITERAL = Pattern.compile(
        '(?:(?:LAST|NEXT)_N_(?:DAYS|WEEKS|MONTHS|QUARTERS|YEARS|FISCAL_QUARTERS|FISCAL_YEARS)|' +
        'N_(?:DAYS|WEEKS|MONTHS|QUARTERS|YEARS|FISCAL_QUARTERS|FISCAL_YEARS)_AGO):[0-9]+'
    );
    private static final Set<String> LITERALS = new Set<String>{
        'TRUE',
        'FALSE',
        'NULL',
        'YESTERDAY',
        'TODAY',
        'TOMORROW',
        'LAST_90_DAYS',
        'NEXT_90_DAYS',
        'LAST_WEEK',
        'THIS_WEEK',
        'NEXT_WEEK',
        'LAST_MONTH',
        'THIS_MONTH',
        'NEXT_MONTH',
        'LAST_QUARTER',
        'THIS_QUARTER',
        'NEXT_QUARTER',
        'LAST_YEAR',
        'THIS_YEAR',
        'NEXT_YEAR',
        'LAST_FISCAL_QUARTER',
        'THIS_FISCAL_QUARTER',
        'NEXT_FISCAL_QUARTER',
        'LAST_FISCAL_YEAR',
        'THIS_FISCAL_YEAR',
        'NEXT_FISCAL_YEAR'
    };
    private static final Set<String> COMPARISONS = new Set<String>{
        '=',
        '!=',
        '<',
        '>',
        '<=',
        '>=',
        'LIKE',
        'NOT LIKE'
    };
    private static final Set<String> ESCAPES = new Set<String>{ '\\', '\'', '"', 'n', 'r', 't', 'b', 'f', '_', '%' };

    public static String validate(String objectName, String condition) {
        return combine(objectName, condition, null);
    }

    /** Keeps semi-joins at the top level while intersecting the two ordinary conditions. */
    public static String combine(String objectName, String jobCondition, String templateCondition) {
        if (String.isBlank(jobCondition) && String.isBlank(templateCondition)) {
            return null;
        }
        Map<String, SObjectType> objects = Schema.getGlobalDescribe();
        SObjectType root = readableObject(objects, objectName);
        Parsed job = new Parser(objects, jobCondition).parse(root);
        Parsed template = new Parser(objects, templateCondition).parse(root);

        List<String> terms = new List<String>();
        if (job.regular != null) {
            Boolean groupJob = template.regular != null || !job.joins.isEmpty() || !template.joins.isEmpty();
            terms.add(groupJob ? '(' + job.regular + ')' : job.regular);
        }
        if (template.regular != null) {
            terms.add('(' + template.regular + ')');
        }
        terms.addAll(job.joins);
        terms.addAll(template.joins);
        if (job.joins.size() + template.joins.size() > MAX_SEMI_JOINS) {
            throw new DocGenException('Invalid filter condition. Use at most two semi-joins or anti-joins.');
        }
        return String.join(terms, ' AND ');
    }

    private class Parsed {
        private String regular;
        private List<String> joins = new List<String>();
    }

    private class Predicate {
        private String text;
        private Boolean isJoin;

        private Predicate(String text, Boolean isJoin) {
            this.text = text;
            this.isJoin = isJoin;
        }
    }

    private class Parser {
        private final Map<String, SObjectType> objects;
        private final String source;
        private Integer position = 0;
        private String current;

        private Parser(Map<String, SObjectType> objects, String condition) {
            this.objects = objects;
            this.source = String.isBlank(condition) ? '' : condition;
        }

        private Parsed parse(SObjectType root) {
            current = readToken();
            if (current == null) {
                return new Parsed();
            }
            Parsed result = expression(root, 0, true);
            if (current != null) {
                throw invalid();
            }
            return result;
        }

        private Parsed expression(SObjectType root, Integer depth, Boolean allowJoin) {
            Parsed result = new Parsed();
            List<String> regular = new List<String>();
            Boolean hasOr = false;
            String connector;
            do {
                Predicate term = predicate(root, depth, allowJoin);
                if (term.isJoin) {
                    result.joins.add(term.text);
                } else {
                    if (!regular.isEmpty()) {
                        regular.add(connector);
                    }
                    regular.add(term.text);
                }
                connector = null;
                if (isToken('AND') || isToken('OR')) {
                    connector = take().toUpperCase();
                    hasOr = hasOr || connector == 'OR';
                }
            } while (connector != null);

            if (hasOr && !result.joins.isEmpty()) {
                throw new DocGenException('Invalid filter condition. Combine semi-joins with top-level AND terms.');
            }
            if (!regular.isEmpty()) {
                result.regular = String.join(regular, ' ');
            }
            return result;
        }

        private Predicate predicate(SObjectType root, Integer depth, Boolean allowJoin) {
            if (depth > MAX_GROUP_DEPTH) {
                throw new DocGenException('Invalid filter condition. The expression is nested too deeply.');
            }
            if (accept('(')) {
                Parsed grouped = expression(root, depth + 1, false);
                expect(')');
                return new Predicate('(' + grouped.regular + ')', false);
            }
            if (accept('NOT')) {
                return new Predicate('NOT ' + predicate(root, depth + 1, false).text, false);
            }

            String path = validateFieldPath(root, identifier());
            String operator = take();
            if (operator == null) {
                throw invalid();
            }
            operator = operator.toUpperCase();
            if (operator == 'NOT') {
                String next = take();
                if (next == null) {
                    throw invalid();
                }
                operator += ' ' + next.toUpperCase();
            }
            if (COMPARISONS.contains(operator)) {
                return new Predicate(path + ' ' + operator + ' ' + literal(), false);
            }
            if (operator == 'IN' || operator == 'NOT IN' || operator == 'INCLUDES' || operator == 'EXCLUDES') {
                expect('(');
                if ((operator == 'IN' || operator == 'NOT IN') && accept('SELECT')) {
                    if (!allowJoin || path.contains('.')) {
                        throw new DocGenException(
                            'Invalid filter condition. Semi-joins require a direct ID or reference field at the top level.'
                        );
                    }
                    return new Predicate(path + ' ' + operator + ' (' + semiJoin(root, path, depth + 1) + ')', true);
                }
                List<String> values = new List<String>{ literal() };
                while (accept(',')) {
                    values.add(literal());
                }
                expect(')');
                return new Predicate(path + ' ' + operator + ' (' + String.join(values, ', ') + ')', false);
            }
            throw invalid();
        }

        private String semiJoin(SObjectType root, String outerPath, Integer depth) {
            String projection = identifier();
            expect('FROM');
            SObjectType innerObject = readableObject(objects, identifier());
            if (root == innerObject || projection.contains('.')) {
                throw new DocGenException(
                    'Invalid filter condition. A semi-join must select a direct field from another object.'
                );
            }
            Schema.DescribeFieldResult outerField = getField(root, outerPath);
            Schema.DescribeFieldResult innerField = getField(innerObject, projection);
            Set<SObjectType> compatible = idTargets(root, outerField);
            compatible.retainAll(idTargets(innerObject, innerField));
            if (compatible.isEmpty()) {
                throw new DocGenException(
                    'Invalid filter condition. Semi-join fields must refer to a common object type.'
                );
            }
            String result = 'SELECT ' + innerField.getName() + ' FROM ' + innerObject.getDescribe().getName();
            if (accept('WHERE')) {
                result += ' WHERE ' + expression(innerObject, depth, false).regular;
            }
            expect(')');
            return result;
        }

        private String identifier() {
            String value = take();
            if (value == null || !FIELD_PATH.matcher(value).matches()) {
                throw invalid();
            }
            return value;
        }

        private String literal() {
            String value = take();
            if (value == null) {
                throw invalid();
            }
            String upper = value.toUpperCase();
            if (
                value.startsWith('\'') ||
                LITERALS.contains(upper) ||
                NUMBER_LITERAL.matcher(value).matches() ||
                DATE_LITERAL.matcher(value).matches() ||
                OFFSET_DATE_LITERAL.matcher(upper).matches()
            ) {
                return value;
            }
            throw invalid();
        }

        private Boolean isToken(String value) {
            return current != null && current.equalsIgnoreCase(value);
        }

        private Boolean accept(String value) {
            if (!isToken(value)) {
                return false;
            }
            current = readToken();
            return true;
        }

        private void expect(String value) {
            if (!accept(value)) {
                throw invalid();
            }
        }

        private String take() {
            String value = current;
            current = readToken();
            return value;
        }

        private String readToken() {
            while (position < source.length() && isWhitespace(source.charAt(position))) {
                position++;
            }
            if (position == source.length()) {
                return null;
            }
            Integer start = position;
            Integer code = source.charAt(position++);
            if (code == 39) {
                return readQuotedLiteral(start);
            }
            if (code == 40 || code == 41 || code == 44 || code == 61) {
                return source.substring(start, position);
            }
            if (code == 33 || code == 60 || code == 62) {
                if (position < source.length() && source.charAt(position) == 61) {
                    position++;
                } else if (code == 33) {
                    throw invalid();
                }
                return source.substring(start, position);
            }
            if (!isWordCharacter(code)) {
                throw invalid();
            }
            while (position < source.length() && isWordCharacter(source.charAt(position))) {
                position++;
            }
            return source.substring(start, position);
        }

        private String readQuotedLiteral(Integer start) {
            while (position < source.length()) {
                Integer code = source.charAt(position++);
                if (code == 39) {
                    return source.substring(start, position);
                }
                if (code == 92) {
                    if (position >= source.length() || !ESCAPES.contains(source.substring(position, position + 1))) {
                        throw invalid();
                    }
                    position++;
                }
            }
            throw invalid();
        }
    }

    private static Boolean isWhitespace(Integer code) {
        return code == 9 || code == 10 || code == 13 || code == 32;
    }

    private static Boolean isWordCharacter(Integer code) {
        return (code >= 48 &&
            code <= 57) ||
            (code >= 65 &&
            code <= 90) ||
            (code >= 97 &&
            code <= 122) ||
            code == 95 ||
            code == 46 ||
            code == 58 ||
            code == 43 ||
            code == 45;
    }

    private static SObjectType readableObject(Map<String, SObjectType> objects, String name) {
        SObjectType objectType = String.isBlank(name) ? null : objects.get(name);
        if (objectType == null || !objectType.getDescribe().isQueryable() || !objectType.getDescribe().isAccessible()) {
            throw new DocGenException('Invalid or inaccessible object.');
        }
        return objectType;
    }

    private static Schema.DescribeFieldResult getField(SObjectType objectType, String name) {
        SObjectField field = objectType.getDescribe().fields.getMap().get(name);
        if (field == null || !field.getDescribe().isAccessible()) {
            throw new DocGenException('Invalid field in filter condition: ' + name);
        }
        return field.getDescribe();
    }

    private static Set<SObjectType> idTargets(SObjectType objectType, Schema.DescribeFieldResult field) {
        if (field.getType() == Schema.DisplayType.ID) {
            return new Set<SObjectType>{ objectType };
        }
        if (field.getType() == Schema.DisplayType.REFERENCE) {
            return new Set<SObjectType>(field.getReferenceTo());
        }
        return new Set<SObjectType>();
    }

    private static String validateFieldPath(SObjectType root, String path) {
        List<String> parts = path.split('\\.');
        if (parts.size() > MAX_RELATIONSHIP_HOPS + 1) {
            throw new DocGenException('Invalid field in filter condition: ' + path);
        }
        List<String> canonical = new List<String>();
        Set<SObjectType> currentTypes = new Set<SObjectType>{ root };
        for (Integer index = 0; index < parts.size() - 1; index++) {
            Set<SObjectType> nextTypes = new Set<SObjectType>();
            String relationship;
            for (SObjectType current : currentTypes) {
                Schema.DescribeFieldResult field = findRelationship(current, parts[index]);
                if (field != null) {
                    relationship = field.getRelationshipName();
                    for (SObjectType target : field.getReferenceTo()) {
                        if (target.getDescribe().isAccessible()) {
                            nextTypes.add(target);
                        }
                    }
                }
            }
            if (nextTypes.isEmpty()) {
                throw new DocGenException('Invalid field in filter condition: ' + path);
            }
            canonical.add(relationship);
            currentTypes = nextTypes;
        }

        String leaf = parts[parts.size() - 1];
        for (SObjectType current : currentTypes) {
            SObjectField field = current.getDescribe().fields.getMap().get(leaf);
            if (field != null && field.getDescribe().isAccessible() && field.getDescribe().isFilterable()) {
                canonical.add(field.getDescribe().getName());
                return String.join(canonical, '.');
            }
        }
        throw new DocGenException('Invalid field in filter condition: ' + path);
    }

    private static Schema.DescribeFieldResult findRelationship(SObjectType root, String relationship) {
        for (SObjectField field : root.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult definition = field.getDescribe();
            if (relationship.equalsIgnoreCase(definition.getRelationshipName()) && definition.isAccessible()) {
                return definition;
            }
        }
        return null;
    }

    private static DocGenException invalid() {
        return new DocGenException('Invalid filter condition.');
    }
}
